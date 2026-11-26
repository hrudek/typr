import Foundation
import XCTest
@testable import HEX

final class TyprOrukeetTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TyprOrukeetTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Setting

    func testSettingDefaultsOnAndPersists() throws {
        let suite = "TyprOrukeetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TyprSettings(defaults: defaults)

        XCTAssertTrue(settings.orukeet)
        XCTAssertNil(defaults.object(forKey: TyprSettings.orukeetKey))
        settings.orukeet = false
        XCTAssertFalse(TyprSettings(defaults: defaults).orukeet)
        settings.orukeet = true
        XCTAssertTrue(TyprSettings(defaults: defaults).orukeet)
        XCTAssertTrue(TyprSettings(defaults: nil).orukeet, "without the App Group")
    }

    // MARK: - Engine choice

    private func language(
        enabled: Bool = true,
        wanted: String? = "de-DE",
        physicalMemory: UInt64 = 8 << 30,
        availableMemory: UInt64 = 0,
        setAside: Bool = false
    ) -> String? {
        TyprOrukeetChoice.language(
            enabled: enabled,
            wanted: wanted,
            physicalMemory: physicalMemory,
            availableMemory: availableMemory,
            setAside: setAside
        )
    }

    func testOffLeavesUpstreamsEngineEvenWithOrukeetReady() {
        XCTAssertNil(language(enabled: false))
        XCTAssertNil(TyprOrukeetChoice.transcriber(language: language(enabled: false), installed: true, compiled: true))
        XCTAssertEqual(
            TyprOrukeetChoice.step(language: language(enabled: false), downloaded: true, installed: true, compiled: true),
            .none
        )
    }

    func testOnTakesItsLanguagesWhereParakeetUltraWouldFit() {
        XCTAssertEqual(language(), "de-DE")
        XCTAssertEqual(language(wanted: "en-US", availableMemory: 2 << 30), "en-US")
        XCTAssertNil(language(wanted: "zh-Hans"), "a language Orukeet doesn't know")
        XCTAssertNil(language(wanted: nil))
        XCTAssertNil(language(physicalMemory: 4 << 30), "an iPhone under Parakeet Ultra's 6 GB")
        XCTAssertNil(language(availableMemory: 1 << 30), "less memory left than a load takes")
        XCTAssertNil(language(setAside: true), "a load that ended Hex")
    }

    func testStepsFromDownloadToDictation() {
        XCTAssertEqual(TyprOrukeetChoice.step(language: "de", downloaded: false, installed: false, compiled: false), .download)
        XCTAssertEqual(TyprOrukeetChoice.step(language: "de", downloaded: true, installed: false, compiled: false), .install)
        XCTAssertEqual(TyprOrukeetChoice.step(language: "de", downloaded: false, installed: true, compiled: false), .loadBeside)
        XCTAssertEqual(TyprOrukeetChoice.step(language: "de", downloaded: false, installed: true, compiled: true), .dictate)
        XCTAssertEqual(TyprOrukeetChoice.step(language: nil, downloaded: true, installed: true, compiled: true), .none)
    }

    func testTranscriberOnlyOnceInstalledAndLoadedOnThisSystem() async {
        XCTAssertNil(TyprOrukeetChoice.transcriber(language: "de-DE", installed: false, compiled: true))
        XCTAssertNil(TyprOrukeetChoice.transcriber(language: "de-DE", installed: true, compiled: false))
        let transcriber = TyprOrukeetChoice.transcriber(language: "de-DE", installed: true, compiled: true)
        XCTAssertEqual(transcriber?.engine, .typrOrukeet)
        let languageIdentifier = await transcriber?.languageIdentifier
        XCTAssertEqual(languageIdentifier, "de-DE")
        XCTAssertEqual(DictationEngine.typrOrukeet.displayName, "Orukeet")
        XCTAssertFalse(DictationEngine.typrOrukeet.keyboardSpeechFollowsApp(keyboardNeedsHex: false))
    }

    func testFailedPreparationFallsBackToUpstreamsEngineWithANotice() {
        typealias Failure = TyprOrukeetTranscriber.TranscriberError
        for error in [Failure.notEnoughMemory, .notInstalled, .loadFailed] {
            XCTAssertNotNil(DictationController.switchNotice(for: error), "\(error)")
        }
        XCTAssertNil(DictationController.switchNotice(for: Failure.emptyTranscript))
        XCTAssertEqual(
            DictationController.switchNotice(for: ParakeetUltraTranscriber.TranscriberError.notEnoughMemory),
            String(localized: "Not enough memory for the multilingual model. Hex is using its usual model.")
        )
    }

    // MARK: - Archive

    func testPinnedEntriesAreTheFourPackagesAndTheVocabularyInsideTheArchive() {
        let paths = TyprOrukeetModel.entries.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        for package in TyprOrukeetModel.packages {
            for file in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
                XCTAssertTrue(paths.contains("\(package).mlpackage/\(file)"), "\(package) \(file)")
            }
        }
        XCTAssertTrue(paths.contains(TyprOrukeetModel.vocabularyFile))
        XCTAssertEqual(paths.count, TyprOrukeetModel.packages.count * 3 + 1)
        for entry in TyprOrukeetModel.entries {
            XCTAssertLessThan(Int64(entry.offset) + entry.compressedSize, TyprOrukeetModel.archive.size, entry.path)
        }
        XCTAssertTrue(TyprOrukeetModel.archive.path.hasPrefix("coreml/\(TyprOrukeetModel.archiveFolder)"))
        XCTAssertTrue(TyprOrukeetModel.baseURL.hasSuffix("/resolve/\(TyprOrukeetModel.revision)"))
    }

    func testCRC32MatchesTheStandardCheckValue() {
        var checksum = TyprCRC32()
        checksum.update(Data("1234".utf8))
        checksum.update(Data("56789".utf8))
        XCTAssertEqual(checksum.value, 0xCBF4_3926)
    }

    func testExtractInflatesAnEntryAndRejectsADamagedOne() throws {
        let content = Data(String(repeating: "orukeet ", count: 500).utf8)
        let (archive, entries) = try makeArchive([("a/b.bin", content)], prefix: Data(repeating: 7, count: 33))
        let archiveURL = directory.appendingPathComponent("test.zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try archive.write(to: archiveURL)
        let destination = directory.appendingPathComponent("out/b.bin")

        try TyprZip.extract(entries[0], from: archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), content)

        let wrongChecksum = TyprZip.Entry(
            path: "a/b.bin", offset: entries[0].offset, compressedSize: entries[0].compressedSize,
            size: entries[0].size, crc32: entries[0].crc32 ^ 1
        )
        XCTAssertThrowsError(try TyprZip.extract(wrongChecksum, from: archiveURL, to: destination)) {
            XCTAssertEqual($0 as? TyprZip.Failure, .damaged)
        }
        let wrongOffset = TyprZip.Entry(
            path: "a/b.bin", offset: 0, compressedSize: entries[0].compressedSize,
            size: entries[0].size, crc32: entries[0].crc32
        )
        XCTAssertThrowsError(try TyprZip.extract(wrongOffset, from: archiveURL, to: destination)) {
            XCTAssertEqual($0 as? TyprZip.Failure, .damaged)
        }
    }

    func testInstallCompilesEachPackageKeepsTheVocabularyAndDeletesTheArchive() async throws {
        let (archive, entries) = try makeArchive(packageFiles())
        let archiveURL = directory.appendingPathComponent(TyprOrukeetModel.archive.path)
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: archiveURL)

        try await TyprOrukeetModel.install(in: directory, entries: entries, compile: Self.fakeCompile)

        XCTAssertTrue(TyprOrukeetModel.isInstalled(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        let compiled = directory.appendingPathComponent("compiled")
        for package in TyprOrukeetModel.packages {
            let manifest = compiled.appendingPathComponent("\(package).mlmodelc/Manifest.json")
            XCTAssertEqual(try Data(contentsOf: manifest), Data("\(package) Manifest.json".utf8))
        }
        XCTAssertEqual(
            try Data(contentsOf: compiled.appendingPathComponent(TyprOrukeetModel.vocabularyFile)),
            Data("vocabulary".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unpacking").path))
    }

    func testInstallDeletesADamagedArchiveSoItDownloadsAgain() async throws {
        let (pristine, entries) = try makeArchive(packageFiles())
        var archive = pristine
        let encoder = try XCTUnwrap(entries.first { $0.path.hasPrefix("Encoder") })
        let name = "\(TyprOrukeetModel.archiveFolder)/\(encoder.path)".utf8.count
        archive[Int(encoder.offset) + 30 + name + 4] ^= 0xFF
        let archiveURL = directory.appendingPathComponent(TyprOrukeetModel.archive.path)
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: archiveURL)

        do {
            try await TyprOrukeetModel.install(in: directory, entries: entries, compile: Self.fakeCompile)
            XCTFail("installed a damaged archive")
        } catch {
            XCTAssertEqual(error as? TyprZip.Failure, .damaged)
        }
        XCTAssertFalse(TyprOrukeetModel.isInstalled(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    // MARK: - Helpers

    private static let fakeCompile: @Sendable (URL) async throws -> URL = { package in
        let output = package.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).mlmodelc")
        try FileManager.default.copyItem(at: package, to: output)
        return output
    }

    private func packageFiles() -> [(String, Data)] {
        TyprOrukeetModel.packages.flatMap { package in
            ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map {
                ("\(package).mlpackage/\($0)", Data("\(package) \($0)".utf8))
            }
        } + [(TyprOrukeetModel.vocabularyFile, Data("vocabulary".utf8))]
    }

    /// Deflated entries behind local headers with a 4-byte extra field, as Oruk AI's archive has.
    private func makeArchive(_ files: [(String, Data)], prefix: Data = Data()) throws -> (Data, [TyprZip.Entry]) {
        var archive = prefix
        var entries: [TyprZip.Entry] = []
        for (path, content) in files {
            let compressed = try (content as NSData).compressed(using: .zlib) as Data
            var checksum = TyprCRC32()
            checksum.update(content)
            let name = Data("\(TyprOrukeetModel.archiveFolder)/\(path)".utf8)
            let offset = UInt64(archive.count)
            for (value, bytes) in [
                (TyprZip.localHeaderSignature, 4), (20, 2), (0, 2), (UInt32(TyprZip.deflated), 2), (0, 2), (0, 2),
                (checksum.value, 4), (UInt32(compressed.count), 4), (UInt32(content.count), 4),
                (UInt32(name.count), 2), (4, 2),
            ] as [(UInt32, Int)] {
                for byte in 0 ..< bytes {
                    archive.append(UInt8((value >> (8 * byte)) & 0xFF))
                }
            }
            archive += name + Data([1, 2, 3, 4]) + compressed
            entries.append(TyprZip.Entry(
                path: path, offset: offset, compressedSize: Int64(compressed.count),
                size: Int64(content.count), crc32: checksum.value
            ))
        }
        return (archive, entries)
    }
}
