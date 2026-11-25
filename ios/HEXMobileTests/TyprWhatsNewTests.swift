import XCTest
@testable import HEX

@MainActor
final class TyprWhatsNewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let changelog = TyprChangelog(sections: [
        .init(id: "typr", title: "Typr", items: [.init(text: "Tastatur heißt jetzt Typr", ref: "#17")]),
        .init(id: "hex", title: "Von Hex", items: [.init(text: "Schnelleres Diktat", ref: nil)]),
    ])
    private let list = WhatsNewRelease(version: "1.0.5", items: [])

    override func setUp() async throws {
        suiteName = "TyprWhatsNewTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func due(
        _ list: WhatsNewRelease?, build: String, changelog: TyprChangelog?, firstRun: Bool = false
    ) -> WhatsNewRelease? {
        TyprWhatsNew.decideAtLaunch(
            TyprWhatsNew.current(list, changelog: changelog),
            changelog: changelog, build: build, defaults: defaults, firstRun: firstRun
        )
    }

    private func markSeen(_ release: WhatsNewRelease, build: String) {
        WhatsNew.markSeen(release, defaults: defaults)
        TyprWhatsNew.markSeen(build: build, defaults: defaults)
    }

    private var recordedBuild: String? { defaults.string(forKey: TyprWhatsNew.lastSeenBuildKey) }

    func testDecodesContractAndIgnoresUnknownKeys() throws {
        let json = """
        {"version":1,"build":"1042","generatedAt":"2026-11-25T22:00:00Z","model":"x",
         "sections":[
          {"id":"typr","title":"Typr","items":[{"text":"Neue Tastenfarbe","ref":"#17","extra":true}]},
          {"id":"hex","title":"Von Hex","items":[{"text":"Schnelleres Diktat"}]}
         ]}
        """
        let decoded = try XCTUnwrap(TyprChangelog.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.sections.map(\.title), ["Typr", "Von Hex"])
        XCTAssertEqual(decoded.sections[0].items, [.init(text: "Neue Tastenfarbe", ref: "#17")])
        XCTAssertEqual(decoded.sections[1].items, [.init(text: "Schnelleres Diktat", ref: nil)])
    }

    func testEmptyMissingOrBrokenChangelogIsNone() {
        XCTAssertNil(TyprChangelog.decode(nil))
        XCTAssertNil(TyprChangelog.decode(Data("not json".utf8)))
        XCTAssertNil(TyprChangelog.decode(Data(#"{"version":1,"sections":[]}"#.utf8)))
        XCTAssertNil(TyprChangelog.decode(Data(#"{"sections":[{"id":"hex","title":"Hex","items":[]}]}"#.utf8)))
        XCTAssertNil(TyprChangelog.bundled(in: Bundle(for: Self.self)))
    }

    func testDropsEmptySections() throws {
        let json = #"{"sections":[{"id":"typr","title":"Typr","items":[]},{"id":"hex","title":"Hex","items":[{"text":"a"}]}]}"#
        XCTAssertEqual(try XCTUnwrap(TyprChangelog.decode(Data(json.utf8))).sections.map(\.id), ["hex"])
    }

    func testCurrentFallsBackToTheBuildAlone() {
        XCTAssertEqual(TyprWhatsNew.current(list, changelog: changelog), list)
        XCTAssertEqual(TyprWhatsNew.current(nil, changelog: changelog)?.version, TyprWhatsNew.buildOnlyVersion)
        XCTAssertEqual(TyprWhatsNew.current(nil, changelog: changelog)?.items, [])
        XCTAssertNil(TyprWhatsNew.current(nil, changelog: nil))
    }

    func testBuildAloneShowsOncePerBuildWhenHexHasNoList() throws {
        markSeen(WhatsNewRelease(version: TyprWhatsNew.buildOnlyVersion, items: []), build: "9.0.0 (1050)")
        XCTAssertNil(due(nil, build: "9.0.0 (1050)", changelog: changelog))

        let shown = try XCTUnwrap(due(nil, build: "9.0.0 (1051)", changelog: changelog))
        XCTAssertEqual(shown.items, [])
        XCTAssertNotNil(due(nil, build: "9.0.0 (1051)", changelog: changelog), "not shown yet")
        markSeen(shown, build: "9.0.0 (1051)")
        XCTAssertNil(due(nil, build: "9.0.0 (1051)", changelog: changelog))
        XCTAssertEqual(recordedBuild, "9.0.0 (1051)")

        XCTAssertNotNil(due(nil, build: "9.1.0 (60)", changelog: changelog), "build numbers restart with a version")
    }

    func testNewListShowsWithTheBuildOnceThenTheNextBuildAlone() throws {
        markSeen(WhatsNewRelease(version: TyprWhatsNew.buildOnlyVersion, items: []), build: "9.0.0 (1050)")
        let combined = try XCTUnwrap(due(list, build: "9.0.0 (1051)", changelog: changelog))
        XCTAssertEqual(combined, list)
        markSeen(combined, build: "9.0.0 (1051)")
        XCTAssertNil(due(list, build: "9.0.0 (1051)", changelog: changelog))

        let next = try XCTUnwrap(due(list, build: "9.0.0 (1052)", changelog: changelog))
        XCTAssertEqual(next.version, "1.0.5", "keeps Hex's list seen")
        XCTAssertEqual(next.items, [], "Hex's list was seen: only the build")
        markSeen(next, build: "9.0.0 (1052)")
        XCTAssertEqual(defaults.string(forKey: WhatsNew.seenKey), "1.0.5")
        XCTAssertNil(due(list, build: "9.0.0 (1052)", changelog: changelog))
    }

    func testHexListStillShowsOnceWithoutAChangelog() {
        XCTAssertEqual(due(list, build: "9.0.0 (1)", changelog: nil), list)
        markSeen(list, build: "9.0.0 (1)")
        XCTAssertNil(due(list, build: "9.0.0 (2)", changelog: nil))
        XCTAssertEqual(recordedBuild, "9.0.0 (2)", "a build without a changelog is recorded silently")
    }

    func testFirstRunRecordsListAndBuildSilently() {
        XCTAssertNil(due(list, build: "9.0.0 (1010)", changelog: changelog, firstRun: true))
        XCTAssertEqual(recordedBuild, "9.0.0 (1010)")
        XCTAssertEqual(defaults.string(forKey: WhatsNew.seenKey), "1.0.5")
        XCTAssertNil(due(list, build: "9.0.0 (1010)", changelog: changelog))
        XCTAssertNil(due(nil, build: "9.0.0 (1011)", changelog: changelog, firstRun: true))
        XCTAssertEqual(recordedBuild, "9.0.0 (1011)")
    }

    func testUpdateFromABuildBeforeTheRecordShows() {
        XCTAssertNotNil(due(nil, build: "9.0.0 (1010)", changelog: changelog))
    }
}
