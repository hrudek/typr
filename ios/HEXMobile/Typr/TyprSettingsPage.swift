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
