import SwiftUI
import UIKit

struct KeyboardAppearancePage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var design = FullKeyboardSettings().design
    @State private var hideSuggestionBar = TyprSettings().hideSuggestionBar
    @State private var globeKey = FullKeyboardSettings().globeKey
    @State private var bottomRow = FullKeyboardSettings().bottomRow
    @State private var numberRow = FullKeyboardSettings().numberRow
    @State private var splitKeyboard = FullKeyboardSettings().splitKeyboard
    @State private var draggedOrder: [BottomKey]?
    @State private var window: WindowReader.Window?

    static let globeKeyFooter = "Only on iPhones with no globe under the keyboard. Spacer keeps 123 off the corner and does nothing when tapped."
    static let switchingKeyboardsHint = "With Spacer or Hidden, hold 123 in the full keyboard or space in the dictation bar to switch keyboards."
    static let bottomRowFooter = "Drag to change the order around the space bar."
    static let splitKeyboardFooter = "Only when iPhone Duo is open and sideways."

    /// `settings-keyboard-appearance-light` and `-dark` fix the preview's appearance for screenshots.
    static func snapshotIsDark(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool? {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return nil }
        return switch arguments[index + 1] {
        case "settings-keyboard-appearance-light": false
        case "settings-keyboard-appearance-dark": true
        default: nil
        }
    }

    private func preview(container: CGSize) -> KeyboardAppearancePreview.Settings {
        KeyboardAppearancePreview.Settings(
            design: design,
            showsSuggestionBar: !hideSuggestionBar,
            globeKey: globeKey,
            bottomRow: BottomRow(order: draggedOrder ?? bottomRow.order, periodKey: bottomRow.periodKey),
            numberRow: numberRow,
            // The app is always dark; the keyboard follows the system like it does in most apps.
            isDark: Self.snapshotIsDark() ?? window?.systemIsDark ?? true,
            container: container,
            splitKeyboard: splitKeyboard
        )
    }

    var body: some View {
        GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Layout preview below")
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
                dockedPreview(in: page.size, foldBottom: Self.horizontalFoldBottom(page), container: window?.size ?? CGSize(
                    width: page.size.width + page.safeAreaInsets.leading + page.safeAreaInsets.trailing,
                    height: page.size.height + page.safeAreaInsets.top + page.safeAreaInsets.bottom
                ))
            }
            .background(WindowReader { window = $0 })
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

    /// The docked preview's scale: full size where the page has room, else leaving the controls 260 pt but taking at
    /// least 35% of the page, and never reaching above a fold across the page (`foldBottom`, in page coordinates).
    static func previewScale(keyboardHeight: CGFloat, page: CGSize, foldBottom: CGFloat?) -> CGFloat {
        var room = max(page.height - 260, page.height * 0.35)
        if let foldBottom { room = min(room, page.height - foldBottom) }
        return min(1, max(0, room) / keyboardHeight)
    }

    /// The width iOS gives a third-party keyboard, centred on the display: on the iPhone Duo narrower than the display
    /// (iikb's measurements in the iOS 27.1 simulator), elsewhere the whole width.
    static func keyboardWidth(display: CGSize) -> CGFloat {
        switch (display.width, display.height) {
        case (466, 678): 452
        case (678, 466): 528
        case (951, 669): 801
        default: display.width
        }
    }

    /// The bottom edge of an active fold running across the page: the iPhone Duo partly open and held upright.
    private static func horizontalFoldBottom(_ page: GeometryProxy) -> CGFloat? {
        guard #available(iOS 27.1, *) else { return nil }
        return page.reservedRegions(kind: .division)
            .map(\.frame)
            .filter { $0.width > $0.height && $0.maxY < page.size.height }
            .map(\.maxY)
            .max()
    }

    private func dockedPreview(in page: CGSize, foldBottom: CGFloat?, container: CGSize) -> some View {
        let settings = preview(container: container)
        let height = KeyboardLayout.height(
            for: settings.orientation, showsStrip: settings.showsSuggestionBar, numberRow: settings.numberRow
        )
        let scale = Self.previewScale(keyboardHeight: height, page: page, foldBottom: foldBottom)
        return KeyboardAppearancePreview(settings: settings)
            .frame(maxWidth: Self.keyboardWidth(display: container), minHeight: height, maxHeight: height)
            .scaleEffect(scale, anchor: .bottom)
            .frame(maxWidth: .infinity, minHeight: height * scale, maxHeight: height * scale, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(settings.accessibilityLabel)
            .background(Self.dockBackdrop(isDark: settings.isDark).ignoresSafeArea(edges: .bottom))
            .ignoresSafeArea(edges: .horizontal)
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

            SettingsSection(title: "Top row") {
                SettingsToggle(title: "Number row", detail: "1 to 0 above the letters. The keyboard grows taller.", isOn: $numberRow)
                    .onChange(of: numberRow) { _, shown in FullKeyboardSettings().numberRow = shown }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Split") {
                    SettingsToggle(title: "Split keyboard", detail: "Half the keys under each thumb.", isOn: $splitKeyboard)
                        .onChange(of: splitKeyboard) { _, split in FullKeyboardSettings().splitKeyboard = split }
                }
                SettingsFooter(Self.splitKeyboardFooter)
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
        design = FullKeyboardSettings().design
        hideSuggestionBar = TyprSettings().hideSuggestionBar
        globeKey = FullKeyboardSettings().globeKey
        bottomRow = FullKeyboardSettings().bottomRow
        numberRow = FullKeyboardSettings().numberRow
        splitKeyboard = FullKeyboardSettings().splitKeyboard
    }
}

/// The window the page is in, which a page beside a sidebar does not fill, and whether the system is dark.
struct WindowReader: UIViewRepresentable {
    struct Window: Equatable {
        var size: CGSize
        var systemIsDark: Bool
    }

    let onChange: (Window) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onChange = onChange
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    /// Laid out whenever the page resizes (rotating, folding, unfolding), which is when the window does.
    final class Probe: UIView {
        var onChange: ((Window) -> Void)?
        private var reported: Window?
        private weak var observedScene: UIWindowScene?
        private var styleRegistration: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let styleRegistration, let observedScene {
                observedScene.unregisterForTraitChanges(styleRegistration)
            }
            observedScene = window?.windowScene
            // The scene's style, not the window's: the app forces its windows dark.
            styleRegistration = observedScene?.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                [weak self] (_: UIWindowScene, _: UITraitCollection) in self?.report()
            }
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window else { return }
            let current = Window(
                size: window.bounds.size,
                systemIsDark: window.windowScene?.traitCollection.userInterfaceStyle != .light
            )
            guard current != reported else { return }
            reported = current
            // Not during SwiftUI's own layout pass.
            DispatchQueue.main.async { [weak self] in self?.onChange?(current) }
        }
    }
}

/// The real full keyboard, drawn only: no touches, text, learning, suggestions or statistics.
struct KeyboardAppearancePreview: UIViewRepresentable {
    struct Settings {
        var design: KeyboardDesign
        var showsSuggestionBar: Bool
        var globeKey: GlobeKey
        var bottomRow: BottomRow
        var numberRow: Bool
        var isDark: Bool
        /// The window the page is in: the display the preview stands in for.
        var container: CGSize
        var splitKeyboard = false

        var orientation: KeyboardOrientation { KeyboardOrientation(container: container, split: splitKeyboard) }

        var accessibilityLabel: String {
            let globe = switch globeKey {
            case .switches: "globe key"
            case .spacer: "globe spacer"
            case .hidden: "no globe key"
            }
            return ["Full keyboard preview", design.title, globe,
                    "period \(bottomRow.periodKey ? "on" : "off")",
                    "number row \(numberRow ? "on" : "off")",
                    orientation == .splitLandscape ? "split" : nil,
                    "suggestions \(showsSuggestionBar ? "shown" : "hidden")"].compactMap { $0 }.joined(separator: ", ")
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
        model.numberRow = settings.numberRow
        model.splitKeyboard = settings.splitKeyboard
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
        view.model.numberRow = settings.numberRow
        view.model.splitKeyboard = settings.splitKeyboard
        view.applyPreview(FullKeyboardView.Preview(design: settings.design, showsSuggestionBar: settings.showsSuggestionBar))
        view.appearanceOverride = settings.isDark
        view.containerSize = settings.container
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
