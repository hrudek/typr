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

/// Typr's part of Hex's What's new: the sheet ends with this build's changelog, and it also
/// shows once after each new build, even when Hex has no list for the version.
@MainActor
enum TyprWhatsNew {
    static let lastSeenBuildKey = "typr.whatsNew.lastSeenBuild"
    /// The version of a What's new that has only this build's changelog.
    static let buildOnlyVersion = "typr-build"

    static let changelog = TyprChangelog.bundled()

    /// Marketing version and build, e.g. "9.0.0 (1042)": build numbers restart with each version.
    static var installedBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return buildLabel(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? ""
        )
    }

    /// "9.0.0 (1042)": shown in the sheet and the key of the show-once record.
    static func buildLabel(version: String, build: String) -> String { "\(version) (\(build))" }

    /// Hex's list for this version, or one with only the changelog when Hex has none.
    static func current(_ list: WhatsNewRelease?, changelog: TyprChangelog? = TyprWhatsNew.changelog) -> WhatsNewRelease? {
        list ?? changelog.map { _ in WhatsNewRelease(version: buildOnlyVersion, items: []) }
    }

    /// Hex's decision, and otherwise this build's changelog alone, once per build. A first run
    /// and a build without a changelog record the build silently; so does nothing else, so an
    /// update from a build before the record shows.
    static func decideAtLaunch(
        _ current: WhatsNewRelease?,
        changelog: TyprChangelog? = TyprWhatsNew.changelog,
        build: String = TyprWhatsNew.installedBuild,
        defaults: UserDefaults,
        firstRun: Bool
    ) -> WhatsNewRelease? {
        let list = current?.version == buildOnlyVersion ? nil : current
        let due = WhatsNew.decideAtLaunch(list, defaults: defaults, firstRun: firstRun)
        if firstRun || changelog == nil {
            markSeen(build: build, defaults: defaults)
            return due
        }
        if defaults.string(forKey: lastSeenBuildKey) == build { return due }
        return due ?? WhatsNewRelease(version: list?.version ?? buildOnlyVersion, items: [])
    }

    static func markSeen(build: String = TyprWhatsNew.installedBuild, defaults: UserDefaults) {
        defaults.set(build, forKey: lastSeenBuildKey)
    }
}

/// "Dieser Build" at the top of Hex's What's new, under the title: the bundled changelog's sections.
struct TyprWhatsNewBuildSection: View {
    let release: WhatsNewRelease

    var body: some View {
        if let changelog = TyprWhatsNew.changelog {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Dieser Build")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(HexTheme.textBase)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: TyprWhatsNew.installedBuild)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HexTheme.textMuted)
                    .padding(.top, -12)
                ForEach(changelog.sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: section.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HexTheme.textMuted)
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•")
                                Text(verbatim: item.text)
                                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(.bottom, release.items.isEmpty ? 0 : 36)
        }
    }
}
