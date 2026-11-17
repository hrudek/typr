@preconcurrency import CoreML
import CryptoKit
import Foundation
import ZIPFoundation

/// Everything that pins Typr's Orukeet engine: Oruk AI's Orukeet r3, a continuation of NVIDIA
/// Parakeet TDT 0.6B V3, as its iOS Core ML archive (INT8 encoder) at an exact revision with its
/// size and SHA-256. Typr compiles the archive's packages on this iPhone and keeps only the
/// compiled models and the vocabulary: compiled models stay valid across iOS updates (Core ML
/// specializes them again on load), so the archive is deleted once installed.
nonisolated enum OrukeetModelSpec: TdtV3ModelSpec {
    struct Marker: Codable, Equatable, Sendable {
        var modelRepo = OrukeetModelSpec.modelRepo
        var modelRevision = OrukeetModelSpec.modelRevision
        var archiveSHA256 = OrukeetModelSpec.archiveSHA256
    }

    static let engine = SpeechEngineChoice.orukeet
    static let storeFolderName = "Orukeet"
    static let markerFileName = "typr-orukeet-installed.json"
    static let preparationFileName = "typr-orukeet-preparation.json"
    static var marker: Marker { Marker() }

    static let modelRepo = "oruk/orukeet"
    static let modelRevision = "419d7f79e290127e202a0f610509868d314743eb"

    static let archive = PinnedModelFile(
        repo: modelRepo, revision: modelRevision,
        path: "coreml/orukeet-r3-coreml-int8sym-encoder-only-experimental-20260920-deflated.zip",
        bytes: 554_985_744)
    static let archiveSHA256 = "24df9ff76f00f86f9ae1fd601cbbcab1d1eac98c7e8107de67444a7858d88b8b"
    static let archiveFolder = "orukeet-r3-coreml-int8sym-encoder-only-experimental-20260920"

    /// The archive entries Typr unpacks, below `archiveFolder`: the four Core ML packages and the vocabulary.
    static let unpackedFiles: [OrukeetArchive.Entry] = [
        entry("Preprocessor.mlpackage/Manifest.json", bytes: 617),
        entry("Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 20_454),
        entry("Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 491_072),
        entry("Decoder.mlpackage/Manifest.json", bytes: 617),
        entry("Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 11_672),
        entry("Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 23_604_992),
        entry("JointDecisionv3.mlpackage/Manifest.json", bytes: 617),
        entry("JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 8_750),
        entry("JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 12_642_764),
        entry("Encoder.mlpackage/Manifest.json", bytes: 617),
        entry("Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 683_341),
        entry("Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 594_211_328),
        vocabularyEntry,
    ]
    static let vocabularyEntry = entry(TdtV3Vocabulary.fileName, bytes: 151_122)

    static let allFiles = [archive]
    static let checkedFiles: [PinnedModelFile] = []
    static let totalBytes = archive.bytes

    static var unpackedBytes: Int64 {
        unpackedFiles.reduce(0) { $0 + $1.bytes }
    }

    /// The unpacked packages and their compiled copies, beside the archive: about 1.82 GB at the peak.
    static var storageHeadroomBytes: Int64 { 2 * unpackedBytes }

    /// Not measured for Orukeet: Whisper's measured requirement (a larger model) is used.
    static let optimizationStorageBytes: Int64 = WhisperModelSpec.optimizationStorageBytes

    /// The archive's joint network is greedy only ("No language hints or top-K vocabulary
    /// reranking", its `optimization.json`): the language is always detected by the model.
    static let acceptsLanguageHint = false

    static func modelFolder(in store: ModelStore<Self>) -> URL {
        store.repoFolder(modelRepo).appending(component: "compiled")
    }

    /// The compiled models and the vocabulary at its exact size; the archive is gone once installed.
    static func filesComplete(in store: ModelStore<Self>) -> Bool {
        let vocabulary = try? store.vocabularyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard vocabulary.map({ Int64($0) }) == vocabularyEntry.bytes else { return false }
        return TdtV3PreparationComponent.allCases.allSatisfy { component in
            var isDirectory: ObjCBool = false
            let url = store.modelFolder.appending(component: component.compiledFolderName)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func entry(_ path: String, bytes: Int64) -> OrukeetArchive.Entry {
        OrukeetArchive.Entry(path: path, bytes: bytes)
    }
}

/// The Orukeet model's store; see `ModelStore` for the meaning of "installed":
///
///     root/models/oruk/orukeet/coreml/<archive>.zip                  (until installed)
///     root/models/oruk/orukeet/compiled/{parakeet_vocab.json, *.mlmodelc/…}
typealias OrukeetModelStore = ModelStore<OrukeetModelSpec>

typealias OrukeetModelInstaller = ModelInstaller<OrukeetModelSpec>

extension ModelInstaller where Spec == OrukeetModelSpec {
    convenience init(
        store: OrukeetModelStore,
        downloader: any ModelFileDownloading,
        unpack: @escaping @Sendable (OrukeetModelStore) async throws -> Void = { try await OrukeetArchive().unpack(into: $0) },
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.init(store: store, downloader: downloader,
                  checkFiles: { _ = try TdtV3Vocabulary.load(from: store.vocabularyURL, for: .orukeet) },
                  unpack: { try await unpack(store) },
                  availableCapacity: availableCapacity)
    }
}

typealias OrukeetTranscriber = TdtV3Transcriber<OrukeetModelSpec>

nonisolated enum OrukeetArchiveError: ModelFileCheckError, Equatable {
    case damaged

    var errorDescription: String? {
        "The Orukeet download is damaged. Tap Retry to download it again."
    }
}

/// Turns the downloaded archive into the compiled models. Only the pinned entries are read, each
/// written to a path Typr builds from its own pinned name, so archive paths never choose a
/// destination. Earlier compiled models are removed first: the install's marker is already gone
/// and the storage check does not count them. A checksum mismatch deletes the archive (Retry
/// downloads it again); any other failure keeps it, so Retry unpacks without downloading.
nonisolated struct OrukeetArchive: Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let bytes: Int64
    }

    var sha256 = OrukeetModelSpec.archiveSHA256
    var folder = OrukeetModelSpec.archiveFolder
    var entries = OrukeetModelSpec.unpackedFiles
    var compile: @Sendable (URL) async throws -> URL = { try await MLModel.compileModel(at: $0) }

    func unpack(into store: OrukeetModelStore) async throws {
        let files = FileManager.default
        let archiveURL = store.fileURL(for: OrukeetModelSpec.archive)
        guard try Self.sha256(of: archiveURL) == sha256 else {
            try files.removeItem(at: archiveURL)
            throw OrukeetArchiveError.damaged
        }
        let staging = store.repoFolder(OrukeetModelSpec.modelRepo).appending(component: "unpacking")
        for stale in [staging, store.modelFolder] where files.fileExists(atPath: stale.path) {
            try files.removeItem(at: stale)
        }
        defer { try? files.removeItem(at: staging) }
        let packages = staging.appending(component: "packages")
        let compiled = staging.appending(component: "compiled")
        try files.createDirectory(at: compiled, withIntermediateDirectories: true)

        let reader = try Archive(url: archiveURL, accessMode: .read)
        for entry in entries {
            try Task.checkCancellation()
            guard let item = reader["\(folder)/\(entry.path)"], item.type == .file,
                  item.uncompressedSize == UInt64(entry.bytes) else {
                throw OrukeetArchiveError.damaged
            }
            _ = try reader.extract(item, to: packages.appending(path: entry.path))
        }
        for component in TdtV3PreparationComponent.allCases {
            try Task.checkCancellation()
            let package = packages.appending(component: "\(component.rawValue).mlpackage")
            let output = try await compile(package)
            try files.moveItem(at: output, to: compiled.appending(component: component.compiledFolderName))
            try files.removeItem(at: package)
        }
        try files.moveItem(at: packages.appending(component: TdtV3Vocabulary.fileName),
                           to: compiled.appending(component: TdtV3Vocabulary.fileName))
        try Task.checkCancellation()
        try files.moveItem(at: compiled, to: store.modelFolder)
        try files.removeItem(at: archiveURL)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
