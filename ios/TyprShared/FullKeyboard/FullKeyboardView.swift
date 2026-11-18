import Combine
import UIKit

/// The full keyboard: a 3-slot suggestion strip (Typr: optional), QWERTY keys with
/// the Typr key right of space, long-press accents, the recording panel that replaces both while
/// Typr records, and the feedback panel that replaces them after a dictation.
/// Dictation state comes from the same `KeyboardViewModel` the dictation bar uses.
@MainActor
final class FullKeyboardView: UIView, UIInputViewAudioFeedback {
    /// The app's settings preview: these values instead of the stored ones, no typing settings and no suggestions.
    struct Preview: Equatable {
        var design: KeyboardDesign
        var showsSuggestionBar: Bool
    }

    let model: KeyboardViewModel
    let engine: FullKeyboardEngine
    weak var hostController: UIInputViewController? {
        didSet { configureGlobe() }
    }

    /// Fixtures force light or dark and portrait or landscape; the keyboard follows its field.
    var appearanceOverride: Bool? { didSet { applyAppearance() } }
    var orientationOverride: KeyboardOrientation? { didSet { setNeedsLayout() } }
    /// Haptics need Full Access.
    var allowsHaptics: () -> Bool = { false }
    /// Draws a stand-in backdrop where there is no system keyboard behind the view.
    var drawsBackdrop = false { didSet { applyAppearance() } }
    /// Typr: sliding down on the Typr key shows the compact dictation bar.
    var allowsCompactBar: Bool {
        get { typrKey.allowsCompactBar }
        set { typrKey.allowsCompactBar = newValue }
    }
    /// Typr: the Typr key was slid down.
    var onShowCompactBar: (() -> Void)?
    /// Fixtures force the suggestion bar on or off; the keyboard follows Typr's switch.
    var suggestionBarOverride: Bool? { didSet { applySuggestionBarSetting() } }
    var designOverride: KeyboardDesign?
    /// How long Fix in Typr stays after Problem before the panel closes itself.
    var problemPanelDuration: TimeInterval {
        get { model.problemPanelDuration }
        set { model.problemPanelDuration = newValue }
    }

    private let stripView = KeyboardStripView()
    private let plane: KeyboardKeyPlaneView
    private let callout = KeyCalloutView()
    private let accentCallout = AccentCalloutView()
    private let typrKey = TyprKeyControl()
    private let globeButton = UIButton(type: .custom)
    private var recordingPanel: TyprKeyRecordingPanel?
    private var feedbackPanel: TyprFeedbackPanel?
    /// What the feedback panel shows; `nil` while the keys are up.
    private var panelContent: TyprFeedbackPanel.Content?
    /// A failure message closed with ✕ stays closed until it changes.
    private var dismissedNotice: String?
    private var styleMenu: TyprStyleMenuView?
    private var palette = FullKeyboardPalette(isDark: false)
    private var didApplyPalette = false
    private(set) var design = KeyboardDesign.standard
    private var subscriptions: Set<AnyCancellable> = []
    private var showsRecording = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private let selectionHaptics = UISelectionFeedbackGenerator()

    /// Exposed so unit tests can verify lazy allocation and teardown of the Metal recording panel.
    var hasAllocatedRecordingPanel: Bool { recordingPanel != nil }
    /// What the feedback panel shows, for tests; `nil` while the keys are up.
    var shownPanelContent: TyprFeedbackPanel.Content? { panelContent }

    init(model: KeyboardViewModel, target: KeyboardTextTarget, autocorrect: AutocorrectEngine? = nil,
         statistics: UsageStatisticsSession? = nil, preview: Preview? = nil) {
        self.model = model
        engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, statistics: statistics)
        engine.autocorrect.learning.onValidatedLabel = { [weak statistics] label, layout in
            statistics?.validatedLabel(label, layout: layout)
        }
        engine.autocorrect.learning.onLabelsInvalidated = { [weak statistics] in
            statistics?.clearRecentLabels()
        }
        plane = KeyboardKeyPlaneView(engine: engine)
        super.init(frame: .zero)
        backgroundColor = .clear

        addSubview(stripView)
        addSubview(plane)
        addSubview(typrKey)
        addSubview(globeButton)
        addSubview(callout)
        addSubview(accentCallout)
        accentCallout.isHidden = true

        stripView.onSelectSuggestion = { [weak self] suggestion in
            guard let self else { return }
            self.keyFeedback()
            self.engine.acceptSuggestion(suggestion)
        }

        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.isAccessibilityElement = true

        typrKey.onHighlightChanged = { [weak self] highlighted in self?.plane.typrPressed = highlighted }
        typrKey.onHold = { [weak self] in self?.typrKeyHeld() }
        typrKey.onTap = { [weak self] in self?.typrKeyTapped() }
        typrKey.onShowCompactBar = { [weak self] in self?.typrKeySlidDown() }
        typrKey.onMenuOpen = { [weak self] point in
            guard let self else { return }
            self.showStyleMenu()
            self.forwardMenuPoint(point, release: false)
        }
        typrKey.onMenuDrag = { [weak self] point in self?.forwardMenuPoint(point, release: false) }
        typrKey.onMenuRelease = { [weak self] point in self?.forwardMenuPoint(point, release: true) }

        plane.onKeyDown = { [weak self] kind in if kind != .globeSpacer { self?.keyFeedback() } }
        plane.onNextKeyboard = { [weak self] in self?.model.onNextKeyboard?() }
        plane.onAccentMenuOpened = { [weak self] in self?.selectionFeedback() }
        engine.onSelectionStep = { [weak self] in self?.selectionFeedback() }
        engine.onChange = { [weak self] in self?.engineChanged() }
        engine.onEdit = { [weak self] in
            self?.model.dismissFeedback()
            self?.refreshReturnKey()
            self?.refreshStrip()
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFromModel() }
            .store(in: &subscriptions)
        model.clock.$recordingText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecordingPanel() }
            .store(in: &subscriptions)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self]) { (view: FullKeyboardView, _) in
            view.applyAppearance()
            view.setNeedsLayout()
        }

        if let preview {
            engine.suspendSuggestions()
            engine.refreshAutoCapitalization()
            applyPreview(preview)
        } else {
            engine.autocorrect.isEnabled = FullKeyboardSettings().autocorrect
            engine.swipeTypingEnabled = FullKeyboardSettings().swipeTyping
            engine.autocorrect.englishEnabled = TyprSettings().autocorrectEnglish
            if TyprSettings().autocorrectGerman {
                let instance = GermanAutocorrect.system()
                cachedGerman = instance
                engine.autocorrect.german = instance
            }
            applySuggestionBarSetting()
            engine.configureForField()
        }
        applyAppearance()
        refreshFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Size

    static func orientation(for traits: UITraitCollection) -> KeyboardOrientation {
        traits.verticalSizeClass == .compact ? .landscape : .portrait
    }

    var orientation: KeyboardOrientation {
        orientationOverride ?? Self.orientation(for: traitCollection)
    }

    var preferredHeight: CGFloat {
        KeyboardLayout.height(for: orientation, showsStrip: engine.showsStrip, numberRow: engine.numberRow)
    }

    // MARK: - Host events

    var enableInputClicksWhenVisible: Bool { true }

    private var cachedGerman: GermanAutocorrect? // Typr

    func warmUpTextCheckerAsync() {
        if engine.autocorrect.isEnabled { engine.autocorrect.spatialDecoder?.prepareResources() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.engine.suggestionsAreActive else { return }
            self.engine.autocorrect.german?.warmUp() // Typr
            guard let checker = self.engine.autocorrect.checker as? SystemTextChecker else { return }
            checker.warmUp()
            self.engine.refreshSuggestions()
        }
    }

    func loadLexicon(_ lexicon: UILexicon) {
        engine.autocorrect.loadLexicon(lexicon)
        engine.refreshSuggestions()
    }

    func loadLexiconEntries(_ entries: [LexiconEntry]) {
        engine.autocorrect.loadLexiconEntries(entries)
        engine.refreshSuggestions()
    }

    func syncSettings() {
        // Learning switch and app reset epochs; never per keystroke.
        engine.autocorrect.syncLearning()
        applySuggestionBarSetting()
        let wantsDesign = designOverride ?? FullKeyboardSettings().design
        if wantsDesign != design {
            design = wantsDesign
            applyAppearance()
        }
        let wantsAutocorrect = FullKeyboardSettings().autocorrect
        if engine.autocorrect.isEnabled != wantsAutocorrect {
            engine.autocorrect.isEnabled = wantsAutocorrect
            engine.refreshSuggestions()
        }
        if wantsAutocorrect { engine.autocorrect.spatialDecoder?.prepareResources() }
        engine.swipeTypingEnabled = FullKeyboardSettings().swipeTyping
        let wantsEnglish = TyprSettings().autocorrectEnglish
        if engine.autocorrect.englishEnabled != wantsEnglish {
            engine.autocorrect.englishEnabled = wantsEnglish
            engine.refreshSuggestions()
        }
        // Cache the German dictionary across language selection changes.
        let wantsGerman = TyprSettings().autocorrectGerman
        if wantsGerman != (engine.autocorrect.german != nil) {
            if wantsGerman {
                let instance = cachedGerman ?? GermanAutocorrect.system()
                cachedGerman = instance
                engine.autocorrect.german = instance
            } else {
                engine.autocorrect.german = nil
            }
            engine.refreshSuggestions()
        }
        // Learning loads/resets (also when consumed by a chip tap), installed spatial resources
        // or an unreported host context change: republish chips that could no longer be accepted.
        engine.refreshSuggestionsIfStale()
    }

    /// The field or its contents changed outside these keys.
    func textDidChange() {
        applyAppearance()
        let field = engine.field
        let route = KeyboardFieldRouting.route(for: engine.target.keyboardType)
        let routeField: KeyboardFieldKind = if case .keys(let kind, _) = route { kind } else { .text }
        if routeField != field {
            plane.cancelAllTouches()
            engine.configureForField()
        } else {
            engine.textDidChange()
        }
        refreshReturnKey()
        refreshStrip()
    }

    /// The keyboard came on screen for a (possibly new) field.
    func prepareForField() {
        syncSettings()
        plane.cancelAllTouches()
        engine.configureForField()
        refreshReturnKey()
        applyAppearance()
        refreshStrip()
        dismissStyleMenu()
        if allowsHaptics() {
            haptics.prepare()
            selectionHaptics.prepare()
        }
    }

    /// Writes pending learning and diagnostics now (dismissal, memory warning, remount).
    func flushLearning() {
        engine.autocorrect.learning.flush()
        engine.endStatisticsSession()
        engine.statistics?.flush()
    }

    /// A late worker or warmup completion must not read a hidden host's document proxy.
    func suspendSuggestions() {
        engine.suspendSuggestions()
    }

    /// Host became active again: only re-enable and refresh the strip. Layer, shift, undo,
    /// touches and the style menu are kept (unlike `prepareForField`).
    func resumeSuggestions() {
        engine.resumeSuggestions()
    }

    /// Selection changes and keyboard dismissal must not retain current-word taps.
    func discardTouchEvidence() {
        engine.endStatisticsSession()
        engine.discardTouchEvidence()
    }

    /// Frees non-essential UI and Metal drawables when the extension approaches its memory ceiling.
    func handleMemoryWarning() {
        flushLearning()
        discardTouchEvidence()
        dismissStyleMenu()
        // The folded swipe tries rebuild on the next swipe; the mapped model weights cost no dirty memory.
        Task { await SwipeRecognizer.shared.releaseLexicons() }
        if !showsRecording, let panel = recordingPanel {
            panel.tearDown()
            panel.removeFromSuperview()
            recordingPanel = nil
        }
    }

    /// Typr inserted a dictation.
    func didInsertDictation() {
        engine.textDidChange()
        refreshReturnKey()
    }

    func applyPreview(_ preview: Preview) {
        suggestionBarOverride = preview.showsSuggestionBar
        design = preview.design
        applyAppearance()
    }

    /// Typr: the suggestion bar follows its switch; the keyboard's height changes with it.
    private func applySuggestionBarSetting() {
        let shows = suggestionBarOverride ?? !TyprSettings().hideSuggestionBar
        guard shows != engine.showsStrip else { return }
        engine.showsStrip = shows
        let visible = shows && !showsRecording && panelContent == nil
        stripView.isHidden = !visible
        stripView.alpha = visible ? 1 : 0
        refreshStrip()
        refreshFeedbackPanel()
        setNeedsLayout()
        hostController?.view.setNeedsLayout()
    }

    /// Fixtures: show a key held down.
    func debugPress(_ character: String) {
        guard let key = engine.layout.key(.character(character)) else { return }
        engine.touchBegan(id: -1, at: CGPoint(x: key.frame.midX, y: key.frame.midY))
    }

    /// Fixtures: show a key's long-press accent callout.
    func debugHoldAccent(_ character: String, selectIndex: Int? = nil) {
        guard let key = engine.layout.key(.character(character)) else { return }
        let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: -2, at: center)
        _ = engine.openAccentMenuIfEligible(forTouch: -2)
        if let selectIndex,
           let menu = engine.activeAccentMenu,
           selectIndex >= 0, selectIndex < menu.cellFrames.count {
            let cell = menu.cellFrames[selectIndex]
            engine.touchMoved(id: -2, to: CGPoint(x: cell.midX, y: center.y))
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let isLandscape = orientation == .landscape
        engine.orientation = orientation
        engine.horizontalInset = isLandscape ? max(safeAreaInsets.left, safeAreaInsets.right) : 0
        engine.width = bounds.width
        let layout = engine.layout

        plane.frame = bounds
        callout.frame = bounds
        accentCallout.frame = bounds
        stripView.frame = layout.stripFrame

        typrKey.joinsSpace = JoinedSpaceKeycap(layout: layout) != nil
        typrKey.cornerRadius = layout.metrics.cornerRadius
        if let key = layout.key(.typr) {
            typrKey.frame = key.hitFrame
            typrKey.keycapFrame = key.frame.offsetBy(dx: -key.hitFrame.minX, dy: -key.hitFrame.minY)
        }
        if let globe = layout.key(.globe) {
            globeButton.isHidden = false
            globeButton.frame = globe.hitFrame
        } else {
            globeButton.isHidden = true
        }

        if let panel = recordingPanel {
            panel.frame = bounds
            panel.horizontalInset = layout.horizontalInset
            panel.metrics = layout.metrics
            panel.sideKeyWidth = layout.letterWidth * KeyboardLayout.modifierWidthRatio
        }
        if let panel = feedbackPanel {
            panel.frame = bounds
            panel.horizontalInset = layout.horizontalInset
            panel.metrics = layout.metrics
        }
        if let menu = styleMenu, let key = layout.key(.typr) {
            menu.frame = bounds
            menu.anchor = key.frame
        }
        plane.setNeedsDisplay()
        updateCallout()
    }

    // MARK: - State

    private func applyAppearance() {
        let isDark = appearanceOverride
            ?? FullKeyboardPalette.isDark(appearance: engine.target.keyboardAppearance, traits: traitCollection)
        let next = FullKeyboardPalette(isDark: isDark, design: design)
        backgroundColor = drawsBackdrop ? next.backdrop : .clear
        stripView.inSystemPlatter = !drawsBackdrop
        guard next != palette || !didApplyPalette else { return }
        didApplyPalette = true
        palette = next
        stripView.palette = next
        plane.palette = next
        callout.palette = next
        callout.setNeedsDisplay()
        accentCallout.palette = next
        typrKey.palette = next
        recordingPanel?.palette = next
        feedbackPanel?.palette = next
        styleMenu?.palette = next
    }

    private func refreshReturnKey() {
        let type = engine.target.returnKeyType ?? .default
        plane.returnLabel = switch type {
        case .go: "go"
        case .google, .yahoo, .search: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "SOS"
        case .continue: "continue"
        default: "return"
        }
        plane.returnSymbol = switch type {
        case .send: "arrow.up"
        case .go, .continue, .route, .join: "arrow.right"
        case .google, .yahoo, .search: "magnifyingglass"
        case .done: "checkmark"
        case .emergencyCall: nil
        default: "return"
        }
        plane.returnIsAction = switch type {
        case .go, .google, .yahoo, .search, .join, .route, .send, .done, .continue, .emergencyCall: true
        default: false
        }
        plane.returnIsEnabled = !(engine.target.enablesReturnKeyAutomatically == true && !engine.target.hasText)
    }

    private func refreshFromModel() {
        typrKey.isWarm = model.hasFullAccess && model.isWarmAvailable
        if engine.showsGlobe != model.needsGlobeKey || engine.globeKey != model.globeKey
            || engine.bottomRow != model.bottomRow || engine.numberRow != model.numberRow {
            engine.showsGlobe = model.needsGlobeKey
            engine.globeKey = model.globeKey
            engine.bottomRow = model.bottomRow
            engine.numberRow = model.numberRow
            setNeedsLayout()
            hostController?.view.setNeedsLayout()
        }
        let recording = model.stagePhase == .recording || model.stagePhase == .transcribing
        if recording != showsRecording {
            setRecording(recording)
        }
        refreshRecordingPanel()
        if let menu = styleMenu {
            menu.style = model.style
        }
        refreshStrip()
        refreshFeedbackPanel()
    }

    private func refreshStrip() {
        let status: String? = if !model.hasFullAccess {
            "Allow Full Access to dictate with Typr"
        } else if model.stagePhase == .failed {
            model.statusMessage
        } else if !model.isWarmAvailable, let notice = model.hostNotice {
            notice
        } else {
            nil
        }
        stripView.update(suggestions: engine.suggestions, statusText: status)
    }

    // MARK: - Feedback panel

    /// The Typr message the hidden suggestion bar would show. Without Full Access there is none:
    /// holding the Typr key opens Typr instead.
    private var hiddenBarNotice: String? {
        guard !engine.showsStrip, model.hasFullAccess else { return nil }
        if model.stagePhase == .failed { return model.statusMessage }
        return model.isWarmAvailable ? nil : model.hostNotice
    }

    private var wantedPanelContent: TyprFeedbackPanel.Content? {
        guard !showsRecording else { return nil }
        if model.hasFullAccess, let feedback = model.feedback {
            return feedback.panelContent
        }
        guard let notice = hiddenBarNotice, notice != dismissedNotice else { return nil }
        return .notice(notice)
    }

    /// Shows, updates or hides the panel over the keys.
    private func refreshFeedbackPanel() {
        if hiddenBarNotice == nil { dismissedNotice = nil }
        let next = wantedPanelContent
        guard next != panelContent else { return }
        let wasShown = panelContent != nil
        panelContent = next
        if let next {
            let panel = feedbackPanel ?? makeFeedbackPanel()
            panel.palette = palette
            panel.content = next
            guard !wasShown else { return }
            plane.cancelAllTouches()
            dismissStyleMenu()
            panel.frame = bounds
            panel.isHidden = false
            var covered = keyViews
            covered.append(accentCallout)
            fade(in: [panel], out: covered)
        } else if let panel = feedbackPanel, wasShown {
            fade(in: showsRecording ? [] : keyViews, out: [panel])
        }
    }

    private func makeFeedbackPanel() -> TyprFeedbackPanel {
        let panel = TyprFeedbackPanel()
        panel.alpha = 0
        panel.isHidden = true
        panel.onGood = { [weak self] in self?.rate("good") }
        panel.onProblem = { [weak self] in self?.rate("bad") }
        panel.onRetry = { [weak self] in
            guard let self, let feedback = self.model.feedback else { return }
            self.rate(feedback.retryRating ?? feedback.rating ?? "bad", issues: feedback.retryIssues)
        }
        panel.onOpen = { [weak self] in
            guard let self, let entryID = self.model.feedback?.offer.entryID else { return }
            self.keyFeedback()
            self.model.dismissFeedback()
            self.model.onOpenURL?(TyprFeedbackLink.url(entryID: entryID))
        }
        panel.onDismiss = { [weak self] in self?.dismissPanel() }
        insertSubview(panel, belowSubview: callout)
        feedbackPanel = panel
        setNeedsLayout()
        return panel
    }

    /// Good closes the panel at once; Problem leaves Fix in Typr and ✕ for a moment.
    private func rate(_ rating: String, issues: [String]? = nil) {
        keyFeedback()
        model.rateFeedback(rating, issues: issues)
    }

    private func dismissPanel() {
        keyFeedback()
        if model.feedback != nil {
            model.dismissFeedback()
        } else if case .notice(let notice)? = panelContent {
            if model.hostNotice == notice {
                model.hostNotice = nil
            } else {
                dismissedNotice = notice
            }
            refreshFeedbackPanel()
        }
    }

    /// The views a panel covers; the suggestion bar only when it is on.
    private var keyViews: [UIView] {
        var views: [UIView] = [plane, typrKey, globeButton, callout]
        if engine.showsStrip { views.insert(stripView, at: 0) }
        return views
    }

    private func refreshRecordingPanel() {
        guard let panel = recordingPanel, showsRecording else { return }
        panel.update(
            phase: model.stagePhase == .transcribing ? .processing : .recording,
            clock: model.clock.recordingText,
            style: model.style
        )
    }

    private func setRecording(_ recording: Bool) {
        showsRecording = recording
        dismissStyleMenu()
        if recording {
            plane.cancelAllTouches()
            let panel = recordingPanel ?? makeRecordingPanel()
            panel.palette = palette
            panel.frame = bounds
            refreshRecordingPanel()
            panel.isHidden = false
            var covered = keyViews
            covered.append(accentCallout)
            if let feedbackPanel { covered.append(feedbackPanel) }
            fade(in: [panel], out: covered)
        } else if let panel = recordingPanel {
            panel.scope.phase = .hidden
            fade(in: keyViews, out: [panel]) { [weak self, weak panel] in
                guard let self, !self.showsRecording, let panel, panel === self.recordingPanel else { return }
                panel.tearDown()
                panel.removeFromSuperview()
                self.recordingPanel = nil
            }
        }
    }

    private func fade(in shown: [UIView], out hidden: [UIView], after: (() -> Void)? = nil) {
        shown.forEach { $0.isHidden = false }
        let globeHidden = engine.layout.key(.globe) == nil
        let accentHidden = engine.activeAccentMenu == nil
        let duration = window == nil ? 0 : 0.18
        if duration == 0 {
            shown.forEach { $0.alpha = 1 }
            hidden.forEach {
                $0.alpha = 0
                $0.isHidden = true
            }
            if globeHidden { globeButton.isHidden = true }
            if accentHidden { accentCallout.isHidden = true }
            after?()
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            shown.forEach { $0.alpha = 1 }
            hidden.forEach { $0.alpha = 0 }
        } completion: { _ in
            for view in hidden where view.alpha == 0 {
                view.isHidden = true
            }
            if globeHidden { self.globeButton.isHidden = true }
            if accentHidden { self.accentCallout.isHidden = true }
            after?()
        }
    }

    private func makeRecordingPanel() -> TyprKeyRecordingPanel {
        let panel = TyprKeyRecordingPanel(loudness: { [weak model] in model?.liveLoudnessDB ?? -62 })
        panel.alpha = 0
        panel.onDone = { [weak self] in self?.model.onStopTap?() }
        panel.onCancel = { [weak self] in self?.model.onCancelTap?() }
        panel.onCycleStyle = { [weak self] in
            guard let self else { return }
            self.model.onStyleSelected?(self.model.style.next)
        }
        insertSubview(panel, belowSubview: callout)
        recordingPanel = panel
        setNeedsLayout()
        return panel
    }

    private func engineChanged() {
        plane.setNeedsDisplay()
        plane.updateTrail()
        updateCallout()
        refreshStrip()
        if globeButton.isHidden != (engine.layout.key(.globe) == nil) || typrKey.frame != engine.layout.key(.typr)?.hitFrame {
            setNeedsLayout()
        }
    }

    private func updateCallout() {
        if let menu = engine.activeAccentMenu {
            callout.show(nil, label: "")
            accentCallout.show(menu)
            return
        }
        accentCallout.show(nil)
        let layout = engine.layout
        if let key = engine.previewKey, let balloon = layout.balloon(for: key) {
            callout.show(balloon, label: engine.displayLabel(for: key))
        } else {
            callout.show(nil, label: "")
        }
    }

    // MARK: - Actions

    private func keyFeedback() {
        UIDevice.current.playInputClick()
        if allowsHaptics() {
            haptics.impactOccurred(intensity: 0.65)
            haptics.prepare()
        }
    }

    private func selectionFeedback() {
        if allowsHaptics() {
            selectionHaptics.selectionChanged()
            selectionHaptics.prepare()
        }
    }

    /// A still hold on the Typr key: dictate, or open Typr.
    private func typrKeyHeld() {
        if allowsHaptics() { haptics.impactOccurred() }
        dismissStyleMenu()
        if typrKey.isWarm {
            model.onDictateTap?()
        } else {
            model.onColdStart?()
        }
    }

    /// Typr: a quick tap on the Typr key types a space, like the space bar.
    private func typrKeyTapped() {
        guard !showsRecording else { return }
        keyFeedback()
        dismissStyleMenu()
        engine.typeSpaceFromTyprKey()
    }

    /// Typr: sliding down on the Typr key shows the compact dictation bar.
    private func typrKeySlidDown() {
        guard !showsRecording, allowsCompactBar else { return }
        if allowsHaptics() { haptics.impactOccurred() }
        dismissStyleMenu()
        plane.cancelAllTouches()
        onShowCompactBar?()
    }

    /// Hold and slide: light the row under the finger, and pick it on release.
    private func forwardMenuPoint(_ point: CGPoint, release: Bool) {
        guard let menu = styleMenu else { return }
        let local = typrKey.convert(point, to: menu)
        if release {
            menu.finishDrag(at: local)
        } else {
            menu.updateDrag(at: local)
        }
    }

    private func showStyleMenu() {
        guard styleMenu == nil, !showsRecording else { return }
        if allowsHaptics() {
            haptics.impactOccurred()
            haptics.prepare()
        }
        plane.cancelAllTouches()
        let menu = TyprStyleMenuView()
        menu.palette = palette
        menu.style = model.style
        menu.onHoverChanged = { [weak self] in self?.selectionFeedback() }
        menu.onStyle = { [weak self] style in
            self?.model.onStyleSelected?(style)
            self?.dismissStyleMenu()
        }
        menu.onDismiss = { [weak self] in self?.dismissStyleMenu() }
        addSubview(menu)
        styleMenu = menu
        setNeedsLayout()
        layoutIfNeeded()
    }

    func dismissStyleMenu() {
        styleMenu?.removeFromSuperview()
        styleMenu = nil
    }

    /// Fixtures: open the menu without a long press.
    func debugShowStyleMenu() {
        showStyleMenu()
    }

    private func configureGlobe() {
        globeButton.removeTarget(nil, action: nil, for: .allEvents)
        if let controller = hostController {
            globeButton.addTarget(
                controller,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
    }
}
