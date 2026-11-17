import AVFAudio
import Observation
import SwiftUI
import UIKit

/// Live keyboard setup state, read from the system and the App Group.
@MainActor
@Observable
final class KeyboardSetupMonitor {
    static let keyboardBundleID = "dev.rudek.typr.keyboard"

    private let bridge: KeyboardBridge

    /// nil when iOS doesn't say which keyboards are enabled.
    private(set) var keyboardAdded: Bool?
    private(set) var fullAccessOn = false
    private(set) var microphone = AVAudioApplication.shared.recordPermission

    init(bridge: KeyboardBridge = KeyboardBridge()) {
        self.bridge = bridge
        refresh()
    }

    var keyboardReady: Bool {
        keyboardAdded == true && fullAccessOn
    }

    func refresh() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--snap-state"), idx + 1 < args.count {
            let snapScene = args[idx + 1]
            if snapScene == "setup" {
                keyboardAdded = true
                fullAccessOn = false
                microphone = .granted
            } else {
                keyboardAdded = true
                fullAccessOn = true
                microphone = .granted
            }
            return
        }

        fullAccessOn = bridge.fullAccessSeenAt != nil
        if let keyboards = UserDefaults.standard.stringArray(forKey: "AppleKeyboards") {
            keyboardAdded = keyboards.contains(Self.keyboardBundleID) || fullAccessOn
        } else {
            keyboardAdded = fullAccessOn ? true : nil
        }
        microphone = AVAudioApplication.shared.recordPermission
    }

    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }
}

struct KeyboardSetupCard: View {
    @Environment(\.openURL) private var openURL
    @Bindable var dictation: DictationController
    let monitor: KeyboardSetupMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard setup")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TyprTheme.textBase)

            VStack(spacing: 0) {
                row(
                    title: "Typr Keyboard",
                    status: keyboardStatus,
                    done: monitor.keyboardAdded == true
                )
                divider
                row(
                    title: "Allow Full Access",
                    status: monitor.fullAccessOn ? "On" : "Off",
                    done: monitor.fullAccessOn
                )
                divider
                row(
                    title: "Microphone",
                    status: microphoneStatus,
                    done: monitor.microphone == .granted
                ) {
                    if monitor.microphone == .undetermined {
                        smallButton("Allow") { monitor.requestMicrophone() }
                    }
                }
                divider
                row(
                    title: "Speech model",
                    status: modelStatus,
                    done: dictation.isModelReady
                )
            }

            if !monitor.keyboardReady || monitor.microphone == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .medium))
                        Text("Open Settings")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(TyprTheme.textBase)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Color.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(TyprTheme.bgBase, in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius, style: .continuous))
    }

    private var keyboardStatus: String {
        switch monitor.keyboardAdded {
        case true?: "Added"
        case false?: "Not added"
        case nil: "Not verified"
        }
    }

    private var microphoneStatus: String {
        switch monitor.microphone {
        case .granted: "Allowed"
        case .denied: "Off"
        default: "Required"
        }
    }

    private var modelStatus: String {
        // Preparation or failure (also while switching engines) wins over an earlier ready state.
        switch dictation.phase {
        case .modelRequired where dictation.preferredEngine?.requiresExplicitDownload == true:
            return "Download required"
        case .preparingModel:
            guard let fraction = dictation.modelPreparation.fractionCompleted else { return "Preparing" }
            return "\(Int(fraction * 100))%"
        case .failed where !dictation.isModelReady || dictation.currentEngine == nil:
            return "Failed"
        default:
            return dictation.isModelReady ? dictation.engineName : "Preparing"
        }
    }

    private func row(title: String, status: String, done: Bool) -> some View {
        row(title: title, status: status, done: done) { EmptyView() }
    }

    private func row<Trailing: View>(
        title: String,
        status: String,
        done: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(done ? TyprTheme.success : TyprTheme.textFaint)

            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(TyprTheme.textBase)

            Spacer(minLength: 8)

            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(TyprTheme.textMuted)
                .lineLimit(1)

            trailing()
        }
        .padding(.vertical, 9)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(TyprTheme.textBase)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.09), in: Capsule())
            .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(TyprTheme.borderWeak)
            .frame(height: 0.5)
    }
}
