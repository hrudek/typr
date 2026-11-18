import Foundation
import Darwin

/// No text crosses this bridge. One immutable atomic event per UUID avoids cross-process
/// UserDefaults array races. The app alone publishes permission; all queue access uses flock.
final class DictationFeedbackBridge: @unchecked Sendable {
    static let permissionKey = "typr.dictationFeedback.permission"
    static let stripKey = "typr.dictationFeedbackStrip"
    static let maximumPending = 100
    static let maximumEventBytes = 16_384
    static let shared = DictationFeedbackBridge()
    private let defaults: UserDefaults?
    private let directory: URL?
    private let queue = DispatchQueue(label: "typr.keyboard-feedback", qos: .utility)

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup),
         directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
            .appendingPathComponent("Typr/DictationFeedback", isDirectory: true)) {
        self.defaults = defaults; self.directory = directory
    }
    var permission: DictationFeedbackPermission? {
        guard let data = defaults?.data(forKey: Self.permissionKey),
              let permission = try? JSONDecoder().decode(DictationFeedbackPermission.self, from: data) else { return nil }
        return permission
    }
    var switchesEnabled: Bool {
        guard let defaults else { return false }
        return (defaults.object(forKey: "typr.dictationLog") as? Bool ?? true)
            && (defaults.object(forKey: Self.stripKey) as? Bool ?? false)
    }
    /// Only the app calls this, once its archive lineage is known. No queue I/O blocks output.
    func publish(_ permission: DictationFeedbackPermission) {
        defaults?.set(try? JSONEncoder().encode(permission), forKey: Self.permissionKey)
    }
    private func protect(_ url: URL, directory: Bool = false) throws {
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                              .posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
    private func withLock<T>(_ work: (URL) throws -> T) throws -> T {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try protect(directory, directory: true)
        let lockURL = directory.appendingPathComponent("queue.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var locked = false
        for attempt in 0..<3 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard locked else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        try protect(lockURL)
        return try work(directory)
    }
    private func eventFiles(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
    private func read(_ url: URL, now: Date) throws -> DictationFeedbackEvent {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumEventBytes + 1) ?? Data()
        guard data.count <= Self.maximumEventBytes else { throw CocoaError(.fileReadCorruptFile) }
        let event = try JSONDecoder().decode(DictationFeedbackEvent.self, from: data)
        guard event.isValid(at: now), url.deletingPathExtension().lastPathComponent == event.eventID.uuidString else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return event
    }
    func enqueue(_ event: DictationFeedbackEvent, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                let success = try self.withLock { root in
                    guard self.switchesEnabled, let permission = self.permission, permission.enabled,
                          permission.archiveID == event.offer.archiveID, permission.generation == event.offer.generation,
                          event.isValid(at: Date()), Date() <= event.offer.expiresAt else { return false }
                    // Explicitly disclosed 30-day expiry; never evict a valid event to make room.
                    for file in try self.eventFiles(root) {
                        if (try? self.read(file, now: Date())) == nil { try FileManager.default.removeItem(at: file) }
                    }
                    let target = root.appendingPathComponent(event.eventID.uuidString + ".json")
                    if FileManager.default.fileExists(atPath: target.path) { return (try? self.read(target, now: Date())) == event }
                    guard try self.eventFiles(root).count < Self.maximumPending else { return false }
                    let data = try JSONEncoder().encode(event)
                    guard data.count <= Self.maximumEventBytes else { return false }
                    try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try self.protect(target)
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.synchronize()
                    return true
                }
                completion(success)
            } catch { completion(false) }
        }
    }
    func pending(completion: @escaping @Sendable ([DictationFeedbackEvent], Bool) -> Void) {
        queue.async {
            do {
                let result = try self.withLock { root -> ([DictationFeedbackEvent], Bool) in
                    var events: [DictationFeedbackEvent] = []; var problem = false
                    for file in try self.eventFiles(root) {
                        do { events.append(try self.read(file, now: Date())) }
                        catch {
                            // Unsupported/corrupt/expired queue events never mutate an archive.
                            // Keyboard only promised Noted, never Saved; absence is not an ACK.
                            problem = true; try FileManager.default.removeItem(at: file)
                        }
                    }
                    return (events.sorted { $0.order < $1.order }, problem)
                }
                completion(result.0, result.1)
            } catch { completion([], true) }
        }
    }
    /// Called only after a durable archive write (or definitive rejection). No saved UI is inferred.
    func remove(_ id: UUID) {
        queue.async {
            try? self.withLock { root in
                let file = root.appendingPathComponent(id.uuidString + ".json")
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    func discardRevoked() {
        queue.async {
            try? self.withLock { root in
                for file in try self.eventFiles(root) {
                    if let event = try? self.read(file, now: Date()),
                       let permission = self.permission,
                       permission.enabled, permission.archiveID == event.offer.archiveID,
                       permission.generation == event.offer.generation { continue }
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }
    func flush() async {
        await withCheckedContinuation { c in queue.async { c.resume() } }
    }
}
