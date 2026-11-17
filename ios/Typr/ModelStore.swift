import Foundation

/// One file at an exact repository revision. `path` is relative to the repository root.
nonisolated struct PinnedModelFile: Equatable, Hashable, Sendable {
    let repo: String
    let revision: String
    let path: String
    let bytes: Int64
}

/// Everything that pins one engine that reaches this iPhone only through its Download button:
/// the exact files, where they live and what the install marker records. Changing the model means
/// changing its spec, never a runtime lookup.
protocol DownloadableModelSpec: Sendable {
    /// What the marker records; any difference (another revision) means not installed.
    associatedtype Marker: Codable, Equatable, Sendable

    static var engine: SpeechEngineChoice { get }
    /// The folder under `Application Support/Typr`.
    static var storeFolderName: String { get }
    static var markerFileName: String { get }
    static var preparationFileName: String { get }
    static var marker: Marker { get }
    /// Download order.
    static var allFiles: [PinnedModelFile] { get }
    /// Small files the installer parses before downloading the rest; damaged ones are downloaded again.
    static var checkedFiles: [PinnedModelFile] { get }
    static var totalBytes: Int64 { get }
    /// Extra free space required beyond the download.
    static var storageHeadroomBytes: Int64 { get }
    /// Free space required before Core ML specializes ("optimizes") the model for this iPhone.
    static var optimizationStorageBytes: Int64 { get }
    /// Core ML specializes again for another model revision.
    static var modelRevision: String { get }
}

extension DownloadableModelSpec {
    /// Approximate download size for the UI.
    static var downloadSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// Where Typr keeps a downloadable model and how it decides "installed": Application Support (not
/// Documents, not the App Group: the keyboard never needs it), excluded from backup. The layout
/// under `root` is the Hugging Face Hub cache layout, so the downloader writes files in place:
///
///     root/models/<repo>/<path>
///     root/<Spec.markerFileName>      (the marker)
///     root/<Spec.preparationFileName> (the last preparation, see `ModelPreparationRecord`)
///
/// Installed means the marker matches the pinned spec AND every pinned file exists with its exact
/// size. A partial or invalid folder is never installed and never selectable. Typr never deletes
/// the model (Delete is out of scope); a failed or cancelled download leaves its files for Retry.
nonisolated struct ModelStore<Spec: DownloadableModelSpec>: Sendable {
    typealias Marker = Spec.Marker
    static var markerFileName: String { Spec.markerFileName }
    static var preparationFileName: String { Spec.preparationFileName }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `Application Support/Typr/<Spec.storeFolderName>` in the app's own container.
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Typr", isDirectory: true)
            .appendingPathComponent(Spec.storeFolderName, isDirectory: true)
    }

    static var production: ModelStore { ModelStore(root: defaultRoot()) }

    /// The Hub cache folder of one repository, built with the same calls as WhisperKit 1.1.1's
    /// `HubApi.localRepoLocation` (`downloadBase.appending(component: "models").appending(component: id)`)
    /// so both always name the same files.
    func repoFolder(_ repo: String) -> URL {
        root.appending(component: "models").appending(component: repo)
    }

    var markerURL: URL {
        root.appendingPathComponent(Spec.markerFileName)
    }

    func fileURL(for file: PinnedModelFile) -> URL {
        repoFolder(file.repo).appending(path: file.path)
    }

    /// The on-disk size, nil when missing or not a regular file.
    func size(of file: PinnedModelFile) -> Int64? {
        let url = fileURL(for: file)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Pinned files that are missing or have a different size.
    func invalidFiles(_ files: [PinnedModelFile] = Spec.allFiles) -> [PinnedModelFile] {
        files.filter { size(of: $0) != $0.bytes }
    }

    var filesComplete: Bool {
        invalidFiles().isEmpty
    }

    /// Bytes of pinned files already present with their exact size.
    var completeBytes: Int64 {
        Spec.allFiles.filter { size(of: $0) == $0.bytes }.reduce(0) { $0 + $1.bytes }
    }

    var hasMarker: Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Spec.Marker.self, from: data) else { return false }
        return marker == Spec.marker
    }

    /// Marker plus every pinned file at its exact size. Checked at launch and before every prepare.
    var isInstalled: Bool {
        hasMarker && filesComplete
    }

    /// Creates the root and excludes it (and so everything below it) from iCloud/device backup.
    func prepareRoot(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func writeMarker() throws {
        let data = try JSONEncoder().encode(Spec.marker)
        try data.write(to: markerURL, options: .atomic)
    }

    func removeMarker(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: markerURL)
    }

    var preparationURL: URL {
        root.appendingPathComponent(Spec.preparationFileName)
    }

    /// The last preparation's record; empty when none was written or it cannot be read.
    var preparationRecord: ModelPreparationRecord {
        guard let data = try? Data(contentsOf: preparationURL),
              let record = try? JSONDecoder().decode(ModelPreparationRecord.self, from: data) else {
            return ModelPreparationRecord()
        }
        return record
    }

    /// Best effort: a record that cannot be written only costs a more cautious next preparation.
    func writePreparationRecord(_ record: ModelPreparationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: preparationURL, options: .atomic)
    }

    /// Free space for important downloads on the volume holding `root`; nil when unknown.
    func availableCapacity() -> Int64? {
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// What Typr knows about Core ML's specialization of a downloaded model. Core ML offers no API to
/// ask whether its cache will be hit, so Typr records the environment of the last successful load
/// (OS build, Typr version and model revision: Core ML specializes again after OS and Typr
/// updates) and whether a
/// preparation was still running when Typr last stopped (iOS terminates Typr when
/// specialization runs out of storage or memory).
nonisolated struct ModelPreparationRecord: Codable, Equatable, Sendable {
    /// `environment` of the last preparation that loaded the model completely.
    var loadedEnvironment: String?
    /// Set before loading, cleared when the load ends. Still set at the next preparation means
    /// the previous one never finished.
    var inProgress = false
}

/// How a preparation proceeds, decided before any model work.
nonisolated enum ModelPreparationPlan: Equatable, Sendable {
    /// The specialization from the last successful load in this environment is expected to be reused.
    case load
    /// Core ML is expected to specialize the model now, with enough free storage (or unknown).
    case optimize
    /// Specialization is expected and the storage it needs is not free. No model work starts.
    case insufficientStorage(available: Int64)

    static func decide(
        record: ModelPreparationRecord,
        environment: String,
        availableBytes: Int64?,
        requiredBytes: Int64
    ) -> ModelPreparationPlan {
        let expectsCache = record.loadedEnvironment == environment && !record.inProgress
        if expectsCache { return .load }
        // Unknown free space never blocks: Core ML reports its own failure.
        if let availableBytes, availableBytes < requiredBytes {
            return .insufficientStorage(available: availableBytes)
        }
        return .optimize
    }

    /// The environment Core ML keys its specialization on, as far as Typr can tell.
    static func currentEnvironment(
        modelRevision: String,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return [processInfo.operatingSystemVersionString, "\(version) (\(build))",
                modelRevision].joined(separator: " | ")
    }
}
