import SwiftUI

/// Settings › Typr › Orukeet, with its status while it downloads, unpacks or loads.
struct TyprOrukeetRow: View {
    @Binding var isOn: Bool

    var body: some View {
        SettingsToggleRow(
            title: "Orukeet speech model",
            detail: "Oruk AI's model for 25 languages, on iPhones with 6 GB of memory. A \(TyprOrukeetModel.downloadSize) download on Wi-Fi.",
            isOn: $isOn
        )
        if isOn {
            TyprOrukeetStatus(turnOff: { isOn = false })
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

/// Upstream's `MultilingualModelStatus` for Orukeet's download, on home and in Settings › Typr.
struct TyprOrukeetStatus: View {
    let turnOff: () -> Void
    private var orukeet: TyprOrukeet { .shared }

    var body: some View {
        MultilingualModelStatus(
            download: orukeet.download,
            retry: { orukeet.retry() },
            turnOff: turnOff,
            useMobileData: { orukeet.useMobileData() }
        )
    }
}
