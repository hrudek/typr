import Compression
import CoreML
import Foundation

/// Oruk AI's Orukeet r3 (a continuation of NVIDIA Parakeet TDT 0.6B v3, 25 languages,
/// CC BY-SA 4.0) as its iOS Core ML archive with an INT8 encoder, pinned to one revision.
/// `ParakeetUltraDownload` fetches the archive and checks its SHA-256; `install` then unpacks
/// the four packages and the vocabulary, compiles the packages for this iPhone and deletes the
/// archive. The compiled folder has Parakeet Ultra's file names, so `ParakeetUltraModel.load`
/// loads it with the repository's FluidAudio.
nonisolated enum TyprOrukeetModel {
    static let repository = "oruk/orukeet"
    static let revision = "419d7f79e290127e202a0f610509868d314743eb"
    static let archiveFolder = "orukeet-r3-coreml-int8sym-encoder-only-experimental-20260920"

    static let archive = ParakeetUltraModel.File(
        path: "coreml/\(archiveFolder)-deflated.zip",
        size: 554_985_744,
        sha256: "24df9ff76f00f86f9ae1fd601cbbcab1d1eac98c7e8107de67444a7858d88b8b"
    )

    static var baseURL: String {
        "https://huggingface.co/\(repository)/resolve/\(revision)"
    }

    static let packages = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static let vocabularyFile = "parakeet_vocab.json"

    /// The archive entries Hex reads, below `archiveFolder`, from its central directory. Every
    /// entry is deflated, none has a data descriptor, and their local headers carry ZIP64
    /// extras, so the sizes come from here rather than from the local headers.
    static let entries: [TyprZip.Entry] = [
        .init(path: "Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", offset: 415, compressedSize: 2_754, size: 11_672, crc32: 0x3152_0355),
        .init(path: "Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", offset: 3_333, compressedSize: 21_821_160, size: 23_604_992, crc32: 0x5a72_103e),
        .init(path: "Decoder.mlpackage/Manifest.json", offset: 21_824_662, compressedSize: 256, size: 617, crc32: 0xb782_37fe),
        .init(path: "Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", offset: 21_825_060, compressedSize: 62_350, size: 683_341, crc32: 0xdf6c_70a3),
        .init(path: "Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", offset: 21_887_574, compressedSize: 521_259_895, size: 594_211_328, crc32: 0xc480_041c),
        .init(path: "Encoder.mlpackage/Manifest.json", offset: 543_147_638, compressedSize: 253, size: 617, crc32: 0xfac8_d97f),
        .init(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", offset: 543_148_033, compressedSize: 2_280, size: 8_750, crc32: 0x6e6c_b400),
        .init(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", offset: 543_150_485, compressedSize: 11_557_186, size: 12_642_764, crc32: 0xd75d_bfff),
        .init(path: "JointDecisionv3.mlpackage/Manifest.json", offset: 554_707_848, compressedSize: 256, size: 617, crc32: 0xbd02_4531),
        .init(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", offset: 554_717_061, compressedSize: 6_776, size: 20_454, crc32: 0x27a6_c30f),
        .init(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", offset: 554_724_006, compressedSize: 186_412, size: 491_072, crc32: 0x9772_d50f),
        .init(path: "Preprocessor.mlpackage/Manifest.json", offset: 554_910_592, compressedSize: 253, size: 617, crc32: 0x6160_27d0),
        .init(path: vocabularyFile, offset: 554_926_741, compressedSize: 48_731, size: 151_122, crc32: 0xc679_7084),
    ]

    /// In the App Group beside upstream's models (`SpeechModelStore`), so the keyboard can read it.
    static var directory: URL {
        SpeechModelStore.root.appendingPathComponent("typr-orukeet-\(revision.prefix(7))", isDirectory: true)
    }

    static var archiveURL: URL { directory.appendingPathComponent(archive.path) }
    static var compiledDirectory: URL { directory.appendingPathComponent("compiled", isDirectory: true) }

    static func isArchiveDownloaded(in directory: URL = directory) -> Bool {
        ParakeetUltraModel.isDownloaded(in: directory, files: [archive])
    }

    static func isInstalled(in directory: URL = directory) -> Bool {
        SpeechModelStore.isComplete(directory.appendingPathComponent("compiled", isDirectory: true))
    }

    static var downloadSize: String {
        ParakeetUltraDownload.size(archive.size)
    }

    /// Unpacks and compiles the downloaded archive into `compiled`, then deletes the archive.
    /// A damaged archive is deleted too, so the next download fetches it again; any other
    /// failure keeps it, so Try again only unpacks.
    static func install(
        in directory: URL = directory,
        entries: [TyprZip.Entry] = entries,
        compile: @Sendable (URL) async throws -> URL = { try await MLModel.compileModel(at: $0) }
    ) async throws {
        let files = FileManager.default
        let archiveURL = directory.appendingPathComponent(archive.path)
        let compiled = directory.appendingPathComponent("compiled", isDirectory: true)
        let staging = directory.appendingPathComponent("unpacking", isDirectory: true)
        try? files.removeItem(at: staging)
        try? files.removeItem(at: compiled)
        defer { try? files.removeItem(at: staging) }
        let unpacked = staging.appendingPathComponent("packages", isDirectory: true)
        let output = staging.appendingPathComponent("compiled", isDirectory: true)
        try files.createDirectory(at: output, withIntermediateDirectories: true)

        func unpack(_ prefix: String) throws {
            for entry in entries where entry.path.hasPrefix(prefix) {
                do {
                    try TyprZip.extract(entry, from: archiveURL, to: unpacked.appendingPathComponent(entry.path))
                } catch TyprZip.Failure.damaged {
                    try? files.removeItem(at: archiveURL)
                    throw TyprZip.Failure.damaged
                }
            }
        }

        for package in packages {
            try unpack("\(package).mlpackage/")
            let source = unpacked.appendingPathComponent("\(package).mlpackage", isDirectory: true)
            let built = try await compile(source)
            try files.moveItem(at: built, to: output.appendingPathComponent("\(package).mlmodelc", isDirectory: true))
            try files.removeItem(at: source)
        }
        try unpack(vocabularyFile)
        try files.moveItem(at: unpacked.appendingPathComponent(vocabularyFile), to: output.appendingPathComponent(vocabularyFile))
        try Task.checkCancellation()
        try files.moveItem(at: output, to: compiled)
        SpeechModelStore.markComplete(compiled)
        try? files.removeItem(at: archiveURL)
    }

    /// The partial archive and any unpacking leftovers go; an installed model stays.
    static func removeUnlessInstalled(from directory: URL = directory) {
        guard !isInstalled(in: directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Reads pinned, deflated entries out of a ZIP archive with Apple's Compression framework.
nonisolated enum TyprZip {
    struct Entry: Equatable, Sendable {
        let path: String
        /// Where its local header starts.
        let offset: UInt64
        let compressedSize: Int64
        let size: Int64
        let crc32: UInt32
    }

    enum Failure: Error, Equatable {
        case damaged
    }

    static let localHeaderSignature: UInt32 = 0x0403_4b50
    static let deflated: UInt16 = 8

    /// Inflates `entry` to `destination` and checks its size and CRC-32. The entry's name in
    /// the archive is never used as a path.
    static func extract(_ entry: Entry, from archive: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        try input.seek(toOffset: entry.offset)
        guard let header = try input.read(upToCount: 30), header.count == 30,
              header.littleEndian(at: 0, bytes: 4) == localHeaderSignature,
              header.littleEndian(at: 8, bytes: 2) == UInt32(deflated) else {
            throw Failure.damaged
        }
        let skip = UInt64(header.littleEndian(at: 26, bytes: 2) + header.littleEndian(at: 28, bytes: 2))
        try input.seek(toOffset: entry.offset + 30 + skip)

        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var checksum = TyprCRC32()
        var written: Int64 = 0
        var writeError: Error?
        let filter = try OutputFilter(.decompress, using: .zlib) { data in
            guard let data else { return }
            checksum.update(data)
            written += Int64(data.count)
            do {
                try output.write(contentsOf: data)
            } catch {
                writeError = error
                throw error
            }
        }
        func inflate(_ step: () throws -> Void) throws {
            do {
                try step()
            } catch {
                throw writeError ?? Failure.damaged
            }
        }
        var remaining = entry.compressedSize
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: Int(min(remaining, 4 << 20))) }
            guard let chunk, !chunk.isEmpty else { throw Failure.damaged }
            try inflate { try filter.write(chunk) }
            remaining -= Int64(chunk.count)
        }
        try inflate { try filter.finalize() }
        guard written == entry.size, checksum.value == entry.crc32 else { throw Failure.damaged }
    }
}

/// ZIP's CRC-32 (IEEE 802.3, reflected).
nonisolated struct TyprCRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        (0 ..< 8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var state = self.state
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for byte in bytes {
                    state = table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
                }
            }
        }
        self.state = state
    }
}

private extension Data {
    func littleEndian(at offset: Int, bytes: Int) -> UInt32 {
        (0 ..< bytes).reduce(UInt32(0)) { value, index in
            value | UInt32(self[startIndex + offset + index]) << (8 * index)
        }
    }
}
