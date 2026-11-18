import Foundation

/// Single ordered I/O owner. Entry files are authoritative; the small index is only a
/// rebuildable projection. No whole-history text array and no latest-snapshot mailbox.
final class DictationLogStorage: @unchecked Sendable {
    static let maximumBytes = 1_000_000 // legacy and individual file read safety, never archive eviction
    let url: URL // schema-1 source, retained until migration has been verified
    let root: URL
    private let queue = DispatchQueue(label: "typr.dictation-log", qos: .utility)
    private let exportQueue = DispatchQueue(label: "typr.dictation-log.export", qos: .utility)
    private let beforeExportStream: @Sendable () -> Void
    private var archiveID = UUID()
    private var metadata: [UUID: DictationLogMetadata] = [:]
    private var ready = false
    private var issue = false
    private var owned = Set<UUID>()
    private var cleanedExports = false
    private var unreadableFiles = 0
    private var indexScheduled = false
    private var tombstones = Set<UUID>()
    private let fm = FileManager.default
    private var entriesURL: URL { root.appendingPathComponent("entries", isDirectory: true) }
    private var exportsURL: URL { root.appendingPathComponent("exports", isDirectory: true) }
    private var deletedURL: URL { root.appendingPathComponent("deleted", isDirectory: true) }

    init(url: URL, beforeExportStream: @escaping @Sendable () -> Void = {}) {
        self.url = url; self.beforeExportStream = beforeExportStream
        root = url.deletingLastPathComponent().appendingPathComponent("DictationLog/v2", isDirectory: true)
    }
    private func entryURL(_ id: UUID) -> URL { entriesURL.appendingPathComponent(id.uuidString + ".json") }
    private func encoder() -> JSONEncoder { JSONEncoder() }
    private func readEntry(_ url: URL) throws -> DictationLogEntry {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let entry = try JSONDecoder().decode(DictationLogEntry.self, from: data)
        guard entry.schemaVersion == 1 || entry.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        return entry
    }
    private func protect(_ url: URL, directory: Bool = false) throws {
        if directory { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
    private func write(_ data: Data, to target: URL) throws {
        try protect(target.deletingLastPathComponent(), directory: true)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try protect(target)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize() // Feedback queue removal may follow: source must be durable first.
    }
    private func writeEntry(_ source: DictationLogEntry) throws {
        guard !tombstones.contains(source.id) else { throw CocoaError(.fileWriteNoPermission) }
        var entry = source; entry.schemaVersion = 2; entry.revision = entry.revision ?? 1
        let data = try encoder().encode(entry)
        try write(data, to: entryURL(entry.id))
        var row = DictationLogMetadata(entry, bytes: data.count)
        row.fileFingerprint = try fingerprint(entryURL(entry.id))
        metadata[entry.id] = row
    }
    private func writeIndex() throws {
        try write(encoder().encode(Array(metadata.values)), to: root.appendingPathComponent("index.json"))
    }
    private func fingerprint(_ file: URL) throws -> String {
        let attrs = try fm.attributesOfItem(atPath: file.path)
        return "\(attrs[.size] ?? 0)-\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attrs[.systemFileNumber] ?? 0)"
    }
    private func scheduleIndex() {
        guard !indexScheduled else { return }; indexScheduled = true
        queue.async {
            self.indexScheduled = false
            do { try self.writeIndex() } catch { self.issue = true }
        }
    }
    private func initialize() throws {
        guard !ready else { return }
        try protect(root, directory: true)
        try protect(entriesURL, directory: true)
        let identity = root.appendingPathComponent("archive-id.json")
        if fm.fileExists(atPath: identity.path) {
            archiveID = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: identity))
        } else { try write(encoder().encode(archiveID), to: identity) }
        try protect(deletedURL, directory: true)
        tombstones = Set(try fm.contentsOfDirectory(at: deletedURL, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        // Reconcile directory names/fingerprints even when an index exists: it cannot hide newer files.
        let cached = (try? JSONDecoder().decode([DictationLogMetadata].self,
            from: Data(contentsOf: root.appendingPathComponent("index.json")))) ?? []
        var cache: [UUID: DictationLogMetadata] = [:]
        for row in cached { cache[row.id] = row }
        metadata = [:]; unreadableFiles = 0
        for file in try fm.contentsOfDirectory(at: entriesURL, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "json" else { continue }
            do {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), tombstones.contains(id) {
                    try fm.removeItem(at: file); continue // Retry deletion interrupted after durable tombstone.
                }
                let signature = try fingerprint(file)
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                   let row = cache[id], row.fileFingerprint == signature, row.status != .transcribing {
                    metadata[id] = row; continue
                }
                var entry = try readEntry(file)
                guard file.deletingPathExtension().lastPathComponent == entry.id.uuidString else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                entry.recap()
                if entry.status == .transcribing && !owned.contains(entry.id) {
                    entry.status = .interrupted; entry.revision = (entry.revision ?? 1) + 1
                    try writeEntry(entry)
                } else {
                    let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                    var row = DictationLogMetadata(entry, bytes: size); row.fileFingerprint = signature
                    metadata[entry.id] = row
                }
            } catch { issue = true; unreadableFiles += 1 } // Preserve unknown/corrupt originals, never auto-delete.
        }
        do { try migrate() } catch { issue = true } // Preserve source; unrelated captures can still save.
        try writeIndex()
        // Remove stale *owned* export workspaces only on startup, never a live share sheet.
        if !cleanedExports {
            if fm.fileExists(atPath: exportsURL.path) { try fm.removeItem(at: exportsURL) }
            cleanedExports = true
        }
        ready = true
    }
    private func readLegacy() throws -> DictationLogDocument {
        try protect(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let legacy = try JSONDecoder().decode(DictationLogDocument.self, from: data)
        guard legacy.schemaVersion == 1, legacy.entries.allSatisfy({ $0.schemaVersion == 1 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return legacy
    }
    private func scrubLegacy(_ ids: Set<UUID>) throws {
        guard fm.fileExists(atPath: url.path), var legacy = try? readLegacy() else { return }
        let count = legacy.entries.count
        legacy.entries.removeAll { ids.contains($0.id) }
        guard legacy.entries.count != count else { return }
        try encoder().encode(legacy).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try protect(url)
    }
    private func migrate() throws {
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            let legacy = try readLegacy()
            var unresolved = false
            for var entry in legacy.entries {
                if tombstones.contains(entry.id) { continue }
                if fm.fileExists(atPath: entryURL(entry.id).path) {
                    // Includes downgrade reappearance: never replace even a corrupt newer copy.
                    if (try? readEntry(entryURL(entry.id))) == nil { unresolved = true }
                    continue
                }
                entry.recap()
                if entry.status == .transcribing { entry.status = .interrupted }
                try writeEntry(entry)
                guard try readEntry(entryURL(entry.id)) == entryWithSchema2(entry) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            guard !unresolved else { throw CocoaError(.fileReadCorruptFile) }
            try write(Data("verified schema-1 copies".utf8), to: root.appendingPathComponent("migration-complete"))
            // Completion is verified before removing the source; failure remains retryable.
            guard try Data(contentsOf: root.appendingPathComponent("migration-complete")) == Data("verified schema-1 copies".utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fm.removeItem(at: url)
        } catch { issue = true; throw error }
    }
    private func entryWithSchema2(_ entry: DictationLogEntry) -> DictationLogEntry {
        var result = entry; result.schemaVersion = 2; result.revision = result.revision ?? 1; return result
    }
    func load(completion: @escaping @Sendable (DictationArchiveLoad) -> Void) {
        queue.async {
            self.ready = false; self.issue = false
            do { try self.initialize() } catch { self.issue = true }
            completion(DictationArchiveLoad(archiveID: self.archiveID,
                metadata: self.metadata.values.sorted { $0.date > $1.date }, problem: self.issue))
        }
    }
    func read(_ id: UUID, completion: @escaping @Sendable (DictationLogEntry?) -> Void) {
        queue.async { completion(try? self.readEntry(self.entryURL(id))) }
    }
    func save(_ entry: DictationLogEntry, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                try self.initialize()
                self.owned.insert(entry.id)
                try self.writeEntry(entry) // Source precedes derived index, independently for every ID.
                self.scheduleIndex(); completion(true)
            } catch { completion(false) }
        }
    }
    func delete(_ ids: [UUID], completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                try self.initialize()
                for id in ids {
                    // A tombstone must precede removal: unfinished migration or a downgrade's
                    // reappearing schema-1 file must never re-import an explicitly deleted UUID.
                    try self.write(Data(id.uuidString.utf8), to: self.deletedURL.appendingPathComponent(id.uuidString + ".deleted"))
                    self.tombstones.insert(id)
                    let file = self.entryURL(id)
                    if self.fm.fileExists(atPath: file.path) { try self.fm.removeItem(at: file) }
                    self.metadata[id] = nil
                }
                try self.scrubLegacy(Set(ids))
                if self.fm.fileExists(atPath: self.exportsURL.path) { try self.fm.removeItem(at: self.exportsURL) }
                try self.writeIndex(); completion(true)
            } catch { completion(false) }
        }
    }
    func clear(archiveID: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                // Delete legacy too, otherwise a retry/relaunch could re-import deleted history.
                if self.fm.fileExists(atPath: self.url.path) { try self.fm.removeItem(at: self.url) }
                if self.fm.fileExists(atPath: self.root.path) { try self.fm.removeItem(at: self.root) }
                self.metadata = [:]; self.owned = []; self.tombstones = []; self.archiveID = archiveID; self.ready = false; self.issue = false
                try self.initialize(); completion(true)
            } catch { self.ready = false; completion(false) }
        }
    }
    /// Snapshot hard links freeze atomic-entry inodes on the I/O queue. Slow streaming then
    /// runs separately: recording, output and subsequent writes never wait for JSON assembly.
    func export(ids: [UUID]?, build: String, completion: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        queue.async {
            let workspace = self.exportsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try self.initialize()
                try self.protect(workspace, directory: true)
                var files: [URL] = []
                for id in (ids ?? self.metadata.values.sorted { $0.date < $1.date }.map(\.id)) {
                    let target = workspace.appendingPathComponent(id.uuidString + ".entry")
                    try self.fm.linkItem(at: self.entryURL(id), to: target); files.append(target)
                }
                let envelope = DictationJSONEnvelope(exportedAt: Date(), archiveID: self.archiveID, appBuild: build,
                    unreadableFiles: self.unreadableFiles, legacyMigrationPending: self.fm.fileExists(atPath: self.url.path))
                let snapshotFiles = files
                let output = workspace.appendingPathComponent("dictation-log.json")
                let json = JSONEncoder(); json.dateEncodingStrategy = .iso8601
                var header = try json.encode(envelope); header.removeLast()
                try self.write(header + Data(",\"entries\":[".utf8), to: output)
                let handle = try FileHandle(forWritingTo: output)
                self.exportQueue.async {
                    self.beforeExportStream()
                    do {
                        do {
                            try handle.seekToEnd()
                            for (offset, file) in snapshotFiles.enumerated() {
                                if offset > 0 { try handle.write(contentsOf: Data(",".utf8)) }
                                try handle.write(contentsOf: json.encode(self.readEntry(file)))
                            }
                            try handle.write(contentsOf: Data("]}".utf8)); try handle.synchronize(); try handle.close()
                        } catch { try? handle.close(); throw error }
                        for file in snapshotFiles { try self.fm.removeItem(at: file) }
                        guard self.fm.fileExists(atPath: output.path) else { throw CocoaError(.fileNoSuchFile) }
                        completion(.success(output))
                    } catch { try? self.fm.removeItem(at: workspace); completion(.failure(error)) }
                }
            } catch { try? self.fm.removeItem(at: workspace); completion(.failure(error)) }
        }
    }
    func removeExport(_ url: URL) {
        queue.async {
            guard url.deletingLastPathComponent().deletingLastPathComponent() == self.exportsURL else { return }
            try? self.fm.removeItem(at: url.deletingLastPathComponent())
        }
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
