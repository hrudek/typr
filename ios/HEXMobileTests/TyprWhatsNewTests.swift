import XCTest
@testable import HEX

final class TyprWhatsNewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let changelog = TyprChangelog(sections: [
        .init(id: "typr", title: "Typr", items: [.init(text: "Tastatur heißt jetzt Typr", ref: "#17")]),
    ])

    override func setUpWithError() throws {
        suiteName = "TyprWhatsNewTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func show(build: Int, changelog: TyprChangelog?, onboarded: Bool = true) -> TyprChangelog? {
        TyprWhatsNew(defaults: defaults).changelogToShow(build: build, changelog: changelog, onboardedBeforeLaunch: onboarded)
    }

    func testDecodesContractAndIgnoresUnknownKeys() throws {
        let json = """
        {"version":1,"build":"1042","generatedAt":"2026-11-25T22:00:00Z","model":"x",
         "sections":[
          {"id":"typr","title":"Typr","items":[{"text":"Neue Tastenfarbe","ref":"#17","extra":true}]},
          {"id":"hex","title":"Von Hex","items":[{"text":"Schnelleres Diktat"}]}
         ]}
        """
        let decoded = try XCTUnwrap(TyprChangelog.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.sections.map(\.id), ["typr", "hex"])
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

    func testFirstInstallRecordsBuildSilently() {
        XCTAssertNil(show(build: 10, changelog: changelog, onboarded: false))
        XCTAssertEqual(defaults.integer(forKey: TyprWhatsNew.lastSeenBuildKey), 10)
        XCTAssertNil(show(build: 10, changelog: changelog))
        XCTAssertEqual(show(build: 11, changelog: changelog), changelog)
    }

    func testUpdateFromBuildBeforeTheRecordShowsUntilSeen() {
        XCTAssertEqual(show(build: 10, changelog: changelog), changelog)
        TyprWhatsNew(defaults: defaults).markSeen(build: 10)
        XCTAssertNil(show(build: 10, changelog: changelog))
    }

    func testShowsUntilSeenOncePerNewerBuild() {
        defaults.set(10, forKey: TyprWhatsNew.lastSeenBuildKey)
        XCTAssertNil(show(build: 9, changelog: changelog))
        XCTAssertNil(show(build: 10, changelog: changelog))
        XCTAssertEqual(show(build: 12, changelog: changelog), changelog)
        XCTAssertEqual(show(build: 12, changelog: changelog), changelog, "not dismissed yet")
        TyprWhatsNew(defaults: defaults).markSeen(build: 12)
        XCTAssertNil(show(build: 12, changelog: changelog))
        XCTAssertEqual(defaults.integer(forKey: TyprWhatsNew.lastSeenBuildKey), 12)
    }

    func testNoChangelogShowsNothingButRecordsBuild() {
        defaults.set(10, forKey: TyprWhatsNew.lastSeenBuildKey)
        XCTAssertNil(show(build: 11, changelog: nil))
        XCTAssertEqual(defaults.integer(forKey: TyprWhatsNew.lastSeenBuildKey), 11)
    }
}
