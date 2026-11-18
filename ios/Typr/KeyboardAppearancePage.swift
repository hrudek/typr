import SwiftUI
import UIKit

struct KeyboardAppearancePage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fullKeyboard = FullKeyboardSettings().isEnabled
    @State private var design = FullKeyboardSettings().design
    @State private var hideSuggestionBar = TyprSettings().hideSuggestionBar
    @State private var globeKey = FullKeyboardSettings().globeKey
    @State private var bottomRow = FullKeyboardSettings().bottomRow
    @State private var draggedOrder: [BottomKey]?
    @State private var systemIsDark = Self.systemIsDark

    static let globeKeyFooter = "Only on iPhones with no globe under the keyboard. Spacer keeps 123 off the corner and does nothing when tapped."
    static let switchingKeyboardsHint = "With Spacer or Hidden, hold 123 in the full keyboard or space in the dictation bar to switch keyboards."
    static let bottomRowFooter = "Drag to change the order around the space bar."

    /// `settings-keyboard-appearance-light` and `-dark` fix the preview's appearance for screenshots.
    static func snapshotIsDark(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool? {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return nil }
        return switch arguments[index + 1] {
        case "settings-keyboard-appearance-light": false
        case "settings-keyboard-appearance-dark": true
        default: nil
        }
    }

    /// The app is always dark; the keyboard follows the system like it does in most apps.
    private static var systemIsDark: Bool {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return screen?.traitCollection.userInterfaceStyle != .light
    }

    static func summary(design: KeyboardDesign, periodKey: Bool) -> String {
        "\(design.title) · Period \(periodKey ? "on" : "off")"
    }

    private var preview: KeyboardAppearancePreview.Settings {
        KeyboardAppearancePreview.Settings(
            design: design,
            showsSuggestionBar: !hideSuggestionBar,
            globeKey: globeKey,
            bottomRow: BottomRow(order: draggedOrder ?? bottomRow.order, periodKey: bottomRow.periodKey),
            isDark: Self.snapshotIsDark() ?? systemIsDark,
            orientation: verticalSizeClass == .compact ? .landscape : .portrait
        )
    }

    var body: some View {
        GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(fullKeyboard ? "Layout preview below" : "Full keyboard preview below · currently off")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(TyprTheme.textMuted)
                    controls
                    Text("Globe shown where iOS needs it.")
                        .font(.caption)
                        .foregroundStyle(TyprTheme.textFaint)
                }
                .frame(maxWidth: 500)
                .padding(20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dockedPreview(in: page.size)
            }
        }
        .background(TyprTheme.bgDeep.ignoresSafeArea())
        .navigationTitle(SettingsDestination.keyboardAppearance.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(TyprTheme.bgDeep, for: .navigationBar)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    static func dockBackdrop(isDark: Bool) -> Color {
        Color(uiColor: FullKeyboardPalette(isDark: isDark).backdrop)
    }

    private func dockedPreview(in page: CGSize) -> some View {
        let settings = preview
        let height = KeyboardLayout.height(for: settings.orientation, showsStrip: settings.showsSuggestionBar)
        let scale = min(1, max(page.height - 260, page.height * 0.35) / height)
        return KeyboardAppearancePreview(settings: settings)
            .frame(width: page.width, height: height)
            .scaleEffect(scale, anchor: .bottom)
            .frame(width: page.width, height: height * scale)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(settings.accessibilityLabel)
            .background(Self.dockBackdrop(isDark: settings.isDark).ignoresSafeArea(edges: .bottom))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Design") {
                if dynamicTypeSize.isAccessibilitySize {
                    ForEach(Array(KeyboardDesign.allCases.enumerated()), id: \.element) { index, choice in
                        if index > 0 { SettingsDivider() }
                        SettingsChoiceRow(title: choice.title, isSelected: design == choice) { design = choice }
                    }
                } else {
                    Picker("Design", selection: $design) {
                        ForEach(KeyboardDesign.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(16)
                }
            }
            .onChange(of: design) { _, choice in FullKeyboardSettings().design = choice }

            SettingsSection(title: "Suggestions") {
                SettingsToggle(title: "Hide suggestion bar", detail: "Autocorrect still works on space.", isOn: $hideSuggestionBar)
                    .onChange(of: hideSuggestionBar) { _, hidden in TyprSettings().hideSuggestionBar = hidden }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Globe key") {
                    ForEach(Array(GlobeKey.allCases.enumerated()), id: \.element) { index, choice in
                        if index > 0 { SettingsDivider() }
                        SettingsChoiceRow(title: choice.title, isSelected: globeKey == choice) {
                            globeKey = choice
                            FullKeyboardSettings().globeKey = choice
                        }
                    }
                    SettingsDivider()
                    DisclosureGroup("Switching keyboards") {
                        Text(Self.switchingKeyboardsHint)
                            .font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disclosureGroupStyle(SettingsDisclosureStyle())
                    .padding(.horizontal, 16)
                }
                SettingsFooter(Self.globeKeyFooter)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Bottom row") {
                    SettingsToggle(title: "Period key", detail: "Hold it for more punctuation.", isOn: $bottomRow.periodKey)
                    SettingsDivider()
                    SettingsOrderRows(items: $bottomRow.order, onShownOrder: { draggedOrder = $0 }) { key in
                        HStack {
                            Text(key.title).font(.body).foregroundStyle(TyprTheme.textBase)
                            Spacer(minLength: 8)
                            if key == .period, !bottomRow.periodKey {
                                Text("Hidden").font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .onChange(of: bottomRow) { _, row in FullKeyboardSettings().bottomRow = row }
                SettingsFooter(Self.bottomRowFooter)
            }
        }
    }

    private func refresh() {
        fullKeyboard = FullKeyboardSettings().isEnabled
        design = FullKeyboardSettings().design
        hideSuggestionBar = TyprSettings().hideSuggestionBar
        globeKey = FullKeyboardSettings().globeKey
        bottomRow = FullKeyboardSettings().bottomRow
        systemIsDark = Self.systemIsDark
    }
}

/// The real full keyboard, drawn only: no touches, text, learning, suggestions or statistics.
struct KeyboardAppearancePreview: UIViewRepresentable {
    struct Settings {
        var design: KeyboardDesign
        var showsSuggestionBar: Bool
        var globeKey: GlobeKey
        var bottomRow: BottomRow
        var isDark: Bool
        var orientation: KeyboardOrientation

        var accessibilityLabel: String {
            let globe = switch globeKey {
            case .switches: "globe key"
            case .spacer: "globe spacer"
            case .hidden: "no globe key"
            }
            return ["Full keyboard preview", design.title, globe,
                    "period \(bottomRow.periodKey ? "on" : "off")",
                    "suggestions \(showsSuggestionBar ? "shown" : "hidden")"].joined(separator: ", ")
        }
    }

    let settings: Settings

    func makeUIView(context: Context) -> FullKeyboardView {
        Self.makeKeyboard(settings)
    }

    func updateUIView(_ view: FullKeyboardView, context: Context) {
        Self.apply(settings, to: view)
    }

    static func makeKeyboard(_ settings: Settings) -> FullKeyboardView {
        let model = KeyboardViewModel()
        // Shows the globe choice; the app cannot know whether the current iPhone needs one.
        model.needsGlobeKey = true
        model.globeKey = settings.globeKey
        model.bottomRow = settings.bottomRow
        let learning = KeyboardLearningSession(store: nil, defaults: nil, allowsPersistence: { false })
        let view = FullKeyboardView(
            model: model,
            target: KeyboardPreviewTextTarget(),
            autocorrect: AutocorrectEngine(learning: learning, spatialDecoder: nil),
            preview: FullKeyboardView.Preview(design: settings.design, showsSuggestionBar: settings.showsSuggestionBar)
        )
        view.drawsBackdrop = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        apply(settings, to: view)
        return view
    }

    static func apply(_ settings: Settings, to view: FullKeyboardView) {
        view.model.globeKey = settings.globeKey
        view.model.bottomRow = settings.bottomRow
        view.applyPreview(FullKeyboardView.Preview(design: settings.design, showsSuggestionBar: settings.showsSuggestionBar))
        view.appearanceOverride = settings.isDark
        view.orientationOverride = settings.orientation
    }
}

@MainActor
final class KeyboardPreviewTextTarget: KeyboardTextTarget {
    var documentContextBeforeInput: String? { nil }
    var hasText: Bool { false }
    var autocapitalizationType: UITextAutocapitalizationType? { .sentences }
    var keyboardType: UIKeyboardType? { .default }
    var returnKeyType: UIReturnKeyType? { .default }
    var keyboardAppearance: UIKeyboardAppearance? { nil }
    func insertText(_ text: String) {}
    func deleteBackward() {}
}
