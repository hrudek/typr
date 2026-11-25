import SwiftUI

struct TyprSettingsLink: View {
    var body: some View {
        SettingsDivider(leading: 50)
        NavigationLink {
            TyprSettingsPage()
        } label: {
            SettingsLinkLabel(title: "Typr", icon: "paintbrush")
        }
        .buttonStyle(.plain)
    }
}

struct TyprSettingsPage: View {
    private let settings = TyprSettings()
    @State private var mechanicalKeyboard = TyprSettings().mechanicalKeyboard
    @State private var shownChangelog: TyprChangelog?
    private let changelog = TyprChangelog.bundled()

    var body: some View {
        SettingsPageScaffold(title: "Typr") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Mechanical keyboard design",
                    detail: "Raised keycaps on every keyboard",
                    isOn: $mechanicalKeyboard
                )
            }
            if let changelog {
                SettingsCard {
                    Button {
                        shownChangelog = changelog
                    } label: {
                        SettingsLinkLabel(title: "Was ist neu", icon: "sparkles")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $shownChangelog) { TyprWhatsNewSheet(changelog: $0) }
        .onChange(of: mechanicalKeyboard) { _, on in settings.mechanicalKeyboard = on }
    }
}
