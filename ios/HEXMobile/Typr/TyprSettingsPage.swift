import SwiftUI

/// The home screen's Typr row, under Hex's own settings pages.
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

/// Settings › Typr: everything this fork adds on top of Hex.
struct TyprSettingsPage: View {
    let settings: TyprSettings
    @State private var mechanicalKeyboard: Bool

    init(settings: TyprSettings = TyprSettings()) {
        self.settings = settings
        _mechanicalKeyboard = State(initialValue: settings.mechanicalKeyboard)
    }

    var body: some View {
        SettingsPageScaffold(title: "Typr") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Mechanical keyboard design",
                    detail: "Raised keycaps on every keyboard",
                    isOn: $mechanicalKeyboard
                )
            }
        }
        .onChange(of: mechanicalKeyboard) { _, on in settings.mechanicalKeyboard = on }
    }
}
