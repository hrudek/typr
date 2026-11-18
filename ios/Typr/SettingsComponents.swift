import SwiftUI

/// Parsing snapshot routes is read-only. Dedicated simulator fixtures seed their own preferences.
enum SettingsDestination: String, CaseIterable, Hashable {
    case keyboard
    case keyboardAppearance = "keyboard-appearance"
    case statistics
    case autocorrectLanguages = "autocorrect-languages"
    case keyboardWordsPrivacy = "keyboard-words-privacy"
    case keyboardLearnedWords = "keyboard-learned-words"
    // Keep the existing simulator scene name; this is not a persisted user setting.
    case textProcessing = "writing"
    case history
    case speechEngine = "speech-engine"
    case style
    case language

    var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .keyboardAppearance: "Appearance"
        case .statistics: "Statistics"
        case .autocorrectLanguages: "Autocorrect languages"
        case .keyboardWordsPrivacy: "Words and privacy"
        case .keyboardLearnedWords: "Manage learned words"
        case .textProcessing: "AI & vocabulary"
        case .history: "History & feedback"
        case .speechEngine: "Speech engine"
        case .style: "Style"
        case .language: "Language"
        }
    }

    var subtitle: String {
        switch self {
        case .keyboard, .keyboardAppearance, .keyboardWordsPrivacy, .autocorrectLanguages, .statistics,
             .keyboardLearnedWords, .textProcessing, .history: ""
        case .speechEngine: "Automatic chooses an engine until you select one. Audio stays on this iPhone."
        case .style: "Choose how Typr formats your dictations. You can also change style from the keyboard."
        case .language: "Choose the language you dictate in, not a translation language. Your speech engine stays selected."
        }
    }

    static let historySampleScene = "settings-history-sample"
    static let historyDetailScene = "settings-history-sample-detail"

    static func snapshotDestination(arguments: [String]) -> Self? {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return nil }
        let scene = arguments[index + 1]
        if scene == "settings-keyboard-typing" || scene == "settings-keyboard-off" { return .keyboard }
        if scene.hasPrefix("settings-keyboard-appearance-") { return .keyboardAppearance }
        if scene == historySampleScene || scene == historyDetailScene { return .history }
        if StatisticsFixture.launchFixture(arguments: arguments) != nil { return .statistics }
        guard scene.hasPrefix("settings-") else { return nil }
        return Self(rawValue: String(scene.dropFirst("settings-".count)))
    }
}

/// Shared settings surfaces. Keep the keyboard's palette and settings storage unchanged.
struct SettingsSection<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(TyprTheme.textMuted)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                    }
                }
                .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content }
                .background(TyprTheme.bgBase, in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: TyprTheme.cardRadius)
                        .strokeBorder(TyprTheme.borderWeak, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct SettingsDivider: View {
    var leading: CGFloat = 16

    var body: some View {
        Divider().overlay(TyprTheme.borderWeak).padding(.leading, leading)
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body).foregroundStyle(TyprTheme.textBase)
                Text(detail).font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 8)
        }
        .tint(TyprTheme.success)
        .padding(16)
        .frame(minHeight: 64)
    }
}

/// Compact entry point, not a feature card. Explanations belong on the destination.
/// Normal text sizes use one line; accessibility sizes may wrap without clipping.
struct SettingsLink: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let detail: String
    var icon: String? = nil
    var value: String? = nil
    var external = false

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(TyprTheme.textBase)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    titleLabel
                    if let value { valueLabel(value) }
                }
                Spacer(minLength: 0)
            } else {
                titleLabel.lineLimit(1).layoutPriority(1)
                Spacer(minLength: 8)
                if let value { valueLabel(value).lineLimit(1) }
            }
            Image(systemName: external ? "arrow.up.right" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TyprTheme.textFaint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    private var titleLabel: some View {
        Text(title).font(.body).foregroundStyle(TyprTheme.textBase)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueLabel(_ value: String) -> some View {
        Text(value).font(.subheadline).foregroundStyle(TyprTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Buttons allow tapping the selected duration again to restart or extend a session.
struct SettingsWarmDurationControl: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selected: WarmSessionDuration
    let onSelect: (WarmSessionDuration) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(WarmSessionDuration.allCases, id: \.self) { duration in
                        durationButton(duration).frame(maxWidth: .infinity)
                    }
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(WarmSessionDuration.allCases, id: \.self) { duration in
                        durationButton(duration)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(TyprTheme.layer01)
                .padding(.vertical, visualInset)
        }
        .accessibilityHint("Dictate without switching apps")
    }

    // Inset only the paint, not the 44pt hit targets or the compact row's layout.
    private var visualInset: CGFloat { dynamicTypeSize.isAccessibilitySize ? 0 : 7 }

    private func durationButton(_ duration: WarmSessionDuration) -> some View {
        Button { onSelect(duration) } label: {
            Text(duration.shortLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(duration == selected ? TyprTheme.textBase : TyprTheme.textMuted)
                .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 44 : 36, minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(duration == selected ? TyprTheme.layer02 : .clear)
                        .padding(.vertical, visualInset)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(duration == .off ? "Microphone off" : "Keep microphone warm for \(duration.title)")
        .accessibilityAddTraits(duration == selected ? .isSelected : [])
    }
}

/// Inline at normal iPhone widths, stacked only when larger text or narrow space requires it.
struct SettingsWarmDurationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selected: WarmSessionDuration
    let onSelect: (WarmSessionDuration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    stackedRow
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            title.fixedSize()
                            Spacer(minLength: 8)
                            control.fixedSize(horizontal: true, vertical: false)
                        }
                        stackedRow
                    }
                }
            }
            .frame(minHeight: 50)
        }
        .padding(.horizontal, 16)
    }

    private var title: some View {
        Text("Keep mic warm").font(.body).foregroundStyle(TyprTheme.textBase)
    }

    private var control: some View {
        SettingsWarmDurationControl(selected: selected, onSelect: onSelect)
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 8) { title; control }.padding(.vertical, 8)
    }
}

/// A quiet, consistent disclosure affordance, distinct from primary actions.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(TyprMotion.settleAnimation(reduceMotion: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label.font(.body).foregroundStyle(TyprTheme.textBase)
                    Spacer(minLength: 12)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TyprTheme.textFaint)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.bottom, 16)
            }
        }
    }
}

struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote).foregroundStyle(TyprTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }
}

/// A collapsed explanation inside a settings card.
struct SettingsDisclosure: View {
    let title: String
    let text: String

    var body: some View {
        DisclosureGroup(title) {
            Text(text)
                .font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
        .padding(.horizontal, 16)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(TyprTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                }
                content
            }
            .frame(maxWidth: 500)
            .padding(20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .background(TyprTheme.bgDeep.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(TyprTheme.bgDeep, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
    }
}
