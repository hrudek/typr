import SwiftUI

/// `TyprChangelog.json`, which Typr's TestFlight lane writes into the app bundle. Absent in
/// builds from the repository alone.
struct TyprChangelog: Decodable, Equatable {
    struct Section: Decodable, Equatable {
        let id: String
        let title: String
        let items: [Item]
    }

    struct Item: Decodable, Equatable {
        let text: String
        let ref: String?
    }

    let sections: [Section]

    /// The changelog with its empty sections dropped, or nil when nothing is left, the data is
    /// missing or it doesn't decode.
    static func decode(_ data: Data?) -> TyprChangelog? {
        guard let data, let changelog = try? JSONDecoder().decode(TyprChangelog.self, from: data) else {
            return nil
        }
        let sections = changelog.sections.filter { !$0.items.isEmpty }
        return sections.isEmpty ? nil : TyprChangelog(sections: sections)
    }

    static func bundled(in bundle: Bundle = .main) -> TyprChangelog? {
        decode(bundle.url(forResource: "TyprChangelog", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }
}

/// Which build's changelog was last shown, in the app's own UserDefaults.
struct TyprWhatsNew {
    static let lastSeenBuildKey = "typr.whatsNew.lastSeenBuild"

    let defaults: UserDefaults

    /// The changelog to show at launch until `markSeen` records its build. Any build other than
    /// the recorded one is new: build numbers restart with each marketing version. A build with
    /// nothing to show is recorded right away: a first launch records it silently, unless
    /// onboarding was already done before it, which means an update from a build that predates
    /// the record.
    func changelogToShow(build: String, changelog: TyprChangelog?, onboardedBeforeLaunch: Bool) -> TyprChangelog? {
        let lastSeen = defaults.string(forKey: Self.lastSeenBuildKey)
        if build == lastSeen { return nil }
        guard let changelog, lastSeen != nil || onboardedBeforeLaunch else {
            markSeen(build: build)
            return nil
        }
        return changelog
    }

    func markSeen(build: String) {
        defaults.set(build, forKey: Self.lastSeenBuildKey)
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Marketing version and build, e.g. "9.0.0 (1042)".
    static var installedBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "\(version) (\(currentBuild))"
    }
}

extension TyprChangelog: Identifiable {
    var id: String { "changelog" }
}

struct TyprWhatsNewSheet: View {
    let changelog: TyprChangelog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Neu in Build \(TyprWhatsNew.currentBuild)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(HexTheme.textBase)
                ForEach(changelog.sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: section.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HexTheme.textMuted)
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•")
                                Text(verbatim: item.text)
                                Spacer(minLength: 0)
                                if let ref = item.ref {
                                    Text(verbatim: ref)
                                        .font(.system(size: 12))
                                        .foregroundStyle(HexTheme.textMuted)
                                }
                            }
                            .font(.system(size: 15))
                            .foregroundStyle(HexTheme.textBase)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HexTheme.bgBase)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }
}

private struct TyprWhatsNewAtLaunch: ViewModifier {
    @State private var changelog: TyprChangelog?
    @State private var isOnScreen = false
    private let whatsNew = TyprWhatsNew(defaults: .standard)
    private let build = TyprWhatsNew.installedBuild

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                guard !OnboardingFixture.isSnapshot else { return }
                changelog = whatsNew.changelogToShow(
                    build: build,
                    changelog: .bundled(),
                    onboardedBeforeLaunch: OnboardingProgress.launchPage == nil
                )
            }
            .onDisappear { isOnScreen = false }
            .sheet(item: $changelog, onDismiss: {
                // Home going away (a keyboard opening Typr) also dismisses the sheet; only a
                // dismissal while Home stays counts as seen.
                if isOnScreen { whatsNew.markSeen(build: build) }
            }) { TyprWhatsNewSheet(changelog: $0) }
    }
}

extension View {
    /// Shows the bundled changelog once after an update (`TyprWhatsNew`).
    func typrWhatsNew() -> some View {
        modifier(TyprWhatsNewAtLaunch())
    }
}
