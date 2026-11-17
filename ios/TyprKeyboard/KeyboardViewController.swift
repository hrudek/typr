import SwiftUI
import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let bridge = KeyboardBridge()
    private let feedbackBridge = DictationFeedbackBridge.shared
    private var ownedFeedbackJobs = Set<String>()
    private var lastFeedbackEventID: UUID?
    private var confirmedFeedback: DictationFeedbackPresentation?
    private var confirmedFeedbackOrder: DictationFeedbackOrder?
    private let viewModel = KeyboardViewModel()
    private var pollTimer: Timer?
    private var coldStartJobID = UUID().uuidString
    private var lastRemountBucket: Int = 0
    private var lastFullAccessNote: TimeInterval = 0
    private var surface: UIView?
    private var fullKeyboard: FullKeyboardView?
    private var heightConstraint: NSLayoutConstraint?
    private var pollInterval: TimeInterval = 0
    private var didHandOffCurrentField = false
    private var didWarmLexicon = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        NotificationCenter.default.addObserver(self, selector: #selector(hostWillResignActive),
                                               name: .NSExtensionHostWillResignActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hostDidBecomeActive),
                                               name: .NSExtensionHostDidBecomeActive, object: nil)
        syncFromBridge(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ownedFeedbackJobs.insert(coldStartJobID)
        if ownedFeedbackJobs.count > 32 { ownedFeedbackJobs = [coldStartJobID] }
        coldStartJobID = UUID().uuidString
        didHandOffCurrentField = false
        KeyboardHost.appeared()
        viewModel.hostNotice = nil
        mountSurface()
        refreshProtectedLexicon()
        fullKeyboard?.prepareForField()
        handOffNumericPadIfNeeded()
        syncFromBridge(animated: false)
        schedulePoll(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        warmFullKeyboardLexiconIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        fullKeyboard?.suspendSuggestions()
        fullKeyboard?.discardTouchEvidence()
        fullKeyboard?.flushLearning()
        pollTimer?.invalidate()
        pollTimer = nil
        viewModel.dismissFeedback()
    }

    /// Control Center, Notification Center, Siri or an alert: stop late suggestion work only.
    /// Current-word taps, undo and rejected pairs stay; host edits still arrive as textDidChange.
    @objc private func hostWillResignActive() {
        fullKeyboard?.suspendSuggestions()
    }

    /// Not `prepareForField()`: returning to the host must not reset layer, shift or undo.
    /// A keyboard touch also resumes suggestions if this notice is missed.
    @objc private func hostDidBecomeActive() {
        guard viewIfLoaded?.window != nil else { return }
        refreshProtectedLexicon()
        fullKeyboard?.resumeSuggestions()
    }

    private func refreshProtectedLexicon() {
        let lexicon = hasFullAccess
            ? ProtectedPersonalLexicon.load(directory: KeyboardLearningStore.sharedDirectory) : .empty
        fullKeyboard?.engine.autocorrect.loadProtectedLexicon(lexicon)
        fullKeyboard?.engine.refreshSuggestions()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        fullKeyboard?.handleMemoryWarning()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let fullKeyboard, heightConstraint?.constant != fullKeyboard.preferredHeight {
            heightConstraint?.constant = fullKeyboard.preferredHeight
            preferredContentSize.height = fullKeyboard.preferredHeight
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        KeyboardHost.harvest()
        if KeyboardFieldRouting.route(for: textDocumentProxy.keyboardType) != .handOff {
            didHandOffCurrentField = false
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        fullKeyboard?.discardTouchEvidence()
        KeyboardHost.harvest()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        KeyboardHost.harvest()
        updateKeyboardTraits()
        fullKeyboard?.textDidChange()
        handOffNumericPadIfNeeded()
    }

    private func handOffNumericPadIfNeeded() {
        guard fullKeyboard != nil else { return }
        if KeyboardFieldRouting.route(for: textDocumentProxy.keyboardType) == .handOff {
            guard !didHandOffCurrentField else { return }
            didHandOffCurrentField = true
            if needsInputModeSwitchKey {
                advanceToNextInputMode()
            }
        } else {
            didHandOffCurrentField = false
        }
    }

    private func warmFullKeyboardLexiconIfNeeded() {
        guard let fullKeyboard else { return }
        fullKeyboard.warmUpTextCheckerAsync()
        guard !didWarmLexicon else { return }
        didWarmLexicon = true
        // UIKit calls this completion on a background queue; it must not be MainActor-isolated.
        requestSupplementaryLexicon(completion: LexiconDelivery.handler { [weak self] entries in
            self?.fullKeyboard?.loadLexiconEntries(entries)
        })
    }

    private func configureView() {
        view.backgroundColor = .clear

        viewModel.inputViewController = self
        viewModel.onDictateTap = { [weak self] in self?.startWarmDictation() }
        viewModel.onStopTap = { [weak self] in self?.stopWarmDictation() }
        viewModel.onCancelTap = { [weak self] in self?.cancelWarmDictation() }
        viewModel.onStyleSelected = { [weak self] style in
            guard let self else { return }
            self.bridge.style = style
            if self.viewModel.style != style {
                self.viewModel.style = style
            }
        }
        viewModel.onColdStart = { [weak self] in self?.coldStart() }
        viewModel.onFeedbackRating = { [weak self] rating, issues in self?.queueFeedback(rating: rating, issues: issues) }
        viewModel.onSpace = { [weak self] in self?.viewModel.dismissFeedback(); self?.textDocumentProxy.insertText(" ") }
        viewModel.onDelete = { [weak self] in self?.viewModel.dismissFeedback(); self?.textDocumentProxy.deleteBackward() }
        viewModel.onReturn = { [weak self] in self?.viewModel.dismissFeedback(); self?.textDocumentProxy.insertText("\n") }
        viewModel.onOpenURL = { [weak self] url in
            guard let self else { return }
            ContainingAppOpener.open(url, from: self)
        }
        viewModel.onShowFullKeyboard = { [weak self] in self?.switchSurface(toCompactBar: false) }

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 140)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
        mountSurface()
    }

    /// The dictation bar, or the full keyboard when its experiment is on (iPhone only).
    /// The compact bar is shown when it was picked; switching is always available.
    /// Only switches while idle.
    private func mountSurface() {
        let experimentOn = FullKeyboardSettings().isEnabled && UIDevice.current.userInterfaceIdiom == .phone
        let wantsFull = KeyboardSurfaceChoice.wantsFullKeyboard(
            experimentOn: experimentOn,
            compactChosen: KeyboardSurfaceChoice().showsCompactBar
        )
        if viewModel.showsFullKeyboardSwitch != experimentOn {
            viewModel.showsFullKeyboardSwitch = experimentOn
        }
        fullKeyboard?.allowsCompactBar = experimentOn
        guard surface == nil || wantsFull != (fullKeyboard != nil) else { return }
        guard surface == nil || viewModel.stagePhase == .idle || viewModel.stagePhase == .failed else { return }

        children.forEach { child in
            child.willMove(toParent: nil)
            child.removeFromParent()
        }
        fullKeyboard?.suspendSuggestions()
        fullKeyboard?.discardTouchEvidence()
        surface?.removeFromSuperview()
        fullKeyboard?.flushLearning()
        fullKeyboard = nil
        didWarmLexicon = false

        let mounted: UIView
        if wantsFull {
            // Learning files are written only with real Full Access on a device; otherwise RAM
            // for this keyboard session.
            #if targetEnvironment(simulator)
            let store: KeyboardLearningStore? = nil
            #else
            let store = hasFullAccess ? KeyboardLearningStore() : nil
            #endif
            let learning = KeyboardLearningSession(
                store: store,
                defaults: UserDefaults(suiteName: KeyboardBridge.appGroup),
                allowsPersistence: { [weak self] in self?.hasFullAccess == true }
            )
            let keyboard = FullKeyboardView(
                model: viewModel,
                target: DocumentProxyTextTarget { [unowned self] in self.textDocumentProxy },
                autocorrect: AutocorrectEngine(learning: learning),
                statistics: UsageStatisticsSession(
                    store: UsageStatisticsStore(directory: store == nil ? nil : KeyboardLearningStore.sharedDirectory),
                    allowsPersistence: { [weak self] in self?.hasFullAccess == true }
                )
            )
            keyboard.hostController = self
            keyboard.allowsHaptics = { [weak self] in self?.hasFullAccess ?? false }
            keyboard.allowsCompactBar = experimentOn
            keyboard.onShowCompactBar = { [weak self] in self?.switchSurface(toCompactBar: true) }
            fullKeyboard = keyboard
            // Surface switches can create a keyboard without another viewWillAppear callback.
            let imports = hasFullAccess
                ? ProtectedPersonalLexicon.load(directory: KeyboardLearningStore.sharedDirectory) : .empty
            keyboard.engine.autocorrect.loadProtectedLexicon(imports)
            mounted = keyboard
            heightConstraint?.constant = keyboard.preferredHeight
        } else {
            let hosting = UIHostingController(rootView: KeyboardSurfaceView(model: viewModel))
            hosting.view.backgroundColor = .clear
            addChild(hosting)
            hosting.didMove(toParent: self)
            mounted = hosting.view
            heightConstraint?.constant = 140
        }
        preferredContentSize.height = heightConstraint?.constant ?? 140
        mounted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mounted)
        NSLayoutConstraint.activate([
            mounted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mounted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mounted.topAnchor.constraint(equalTo: view.topAnchor),
            mounted.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        surface = mounted
        schedulePoll(force: false)
    }

    /// Typr: the compact bar's keyboard key or a slide down on the Typr key picked a surface.
    /// Only while idle.
    private func switchSurface(toCompactBar compact: Bool) {
        guard viewModel.stagePhase == .idle || viewModel.stagePhase == .failed else { return }
        KeyboardSurfaceChoice().showsCompactBar = compact
        // Let the tapped key's touch handling finish before its view goes away.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.viewModel.activeTray != .none {
                self.viewModel.setActiveTray(.none, reduceMotion: true)
            }
            self.mountSurface()
            self.fullKeyboard?.prepareForField()
            self.warmFullKeyboardLexiconIfNeeded()
            self.syncFromBridge(animated: false)
            self.schedulePoll(force: true)
        }
    }

    /// The dictation bar polls at 25 Hz; the full keyboard at 4 Hz, and 30 Hz while recording.
    private func schedulePoll(force: Bool) {
        let busy = viewModel.stagePhase == .recording || viewModel.stagePhase == .transcribing
            || viewModel.pendingCommand != nil
        let interval: TimeInterval = fullKeyboard == nil ? 0.04 : (busy ? 1.0 / 30 : 0.25)
        guard force || (pollTimer != nil && interval != pollInterval) else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncFromBridge(animated: true)
            }
        }
    }

    private func queueFeedback(rating: String, issues: [String]?) {
        guard hasFullAccess, feedbackBridge.switchesEnabled, let presentation = viewModel.feedback else { return }
        let offer = presentation.offer
        if confirmedFeedback?.offer != offer { confirmedFeedback = presentation; confirmedFeedbackOrder = nil }
        viewModel.feedback?.message = "Queuing…"
        viewModel.feedback?.rating = rating
        if let issues { viewModel.feedback?.issues = issues }
        let event = DictationFeedbackEvent(eventID: UUID(), offer: offer, rating: rating,
            issues: issues, createdAt: Date())
        lastFeedbackEventID = event.eventID
        feedbackBridge.enqueue(event) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.confirmedFeedback?.offer == offer else { return }
                let current = self.viewModel.feedback
                guard current == nil || current?.offer == offer else { return }
                if success, self.confirmedFeedbackOrder.map({ $0 < event.order }) ?? true {
                    self.confirmedFeedbackOrder = event.order
                    self.confirmedFeedback?.rating = event.rating
                    if let issues = event.issues { self.confirmedFeedback?.issues = issues }
                }
                guard self.lastFeedbackEventID == event.eventID else { return }
                // The full keyboard closes its panel on Good at once: only a failure brings it back.
                guard current != nil || !success else { return }
                self.viewModel.feedback = self.confirmedFeedback
                self.viewModel.feedback?.message = success ? "Noted on keyboard" : "Not queued: full, expired or unavailable"
                if !success {
                    self.viewModel.feedback?.retryRating = event.rating
                    self.viewModel.feedback?.retryIssues = event.issues
                }
            }
        }
    }

    private func syncFromBridge(animated: Bool) {
        let now = Date().timeIntervalSince1970
        updateKeyboardTraits()
        fullKeyboard?.syncSettings()

        #if targetEnvironment(simulator)
        let simSnap = bridge.snapshot()
        let effectiveFullAccess = hasFullAccess || simSnap.isAvailable(at: now)
        #else
        let effectiveFullAccess = hasFullAccess
        #endif

        guard effectiveFullAccess else {
            viewModel.dismissFeedback()
            viewModel.applyBridgeState(
                hasFullAccess: false,
                snapshot: .offline,
                isModelInstalled: false,
                style: viewModel.style,
                now: now,
                clearPending: true,
                animated: animated
            )
            return
        }

        if now - lastFullAccessNote >= 5 {
            lastFullAccessNote = now
            bridge.fullAccessSeenAt = now
        }

        let snap = bridge.snapshot()
        let permission = feedbackBridge.permission
        if !feedbackBridge.switchesEnabled || permission?.enabled != true || snap.state == .recording || snap.state == .transcribing
            || (viewModel.feedback.map { $0.offer.expiresAt < Date() || $0.offer.generation != permission?.generation } ?? false) {
            viewModel.dismissFeedback()
        }
        var insertedResult = false

        if snap.hasDeliverableResult(at: now),
           let resultID = snap.resultID,
           let rawTranscript = snap.transcript,
           bridge.lastInsertedResultID != resultID {
            let insertion = TranscriptFormatter.insertionText(
                for: rawTranscript,
                beforeContext: textDocumentProxy.documentContextBeforeInput,
                afterContext: textDocumentProxy.documentContextAfterInput
            )
            textDocumentProxy.insertText(insertion)
            fullKeyboard?.didInsertDictation()
            bridge.lastInsertedResultID = resultID
            insertedResult = true
            if feedbackBridge.switchesEnabled, snap.state != .recording, snap.state != .transcribing {
                viewModel.feedback = DictationFeedbackPresentation.inserted(offer: snap.feedbackOffer,
                    resultID: resultID, ownedJobs: ownedFeedbackJobs.union(bridge.feedbackJobs).union([coldStartJobID]),
                    permission: permission, now: Date(timeIntervalSince1970: now))
            }
            coldStartJobID = UUID().uuidString
        }

        viewModel.applyBridgeState(
            hasFullAccess: true,
            snapshot: snap,
            isModelInstalled: bridge.isModelInstalled,
            style: bridge.style,
            now: now,
            clearPending: insertedResult,
            animated: animated
        )

        remountIfNeeded(now: now)
        schedulePoll(force: false)
    }

    /// Picks up a changed keyboard setting (full keyboard) every 2 s.
    private func remountIfNeeded(now: TimeInterval) {
        let bucket = Int(now / 2.0)
        guard bucket != lastRemountBucket else { return }
        lastRemountBucket = bucket
        mountSurface()
    }

    /// Opens Typr to start the microphone, naming the app to return to (`KeyboardHost`).
    /// A share sheet, a notification's reply or Spotlight closes once left, taking its text
    /// with it, so from there Typr is not opened; dictation needs a warm mic instead.
    private func coldStart() {
        let host = KeyboardHost.app(of: self)
        guard KeyboardHost.canReturn(to: host) else {
            viewModel.hostNotice = "Turn on Keep mic warm in Typr first"
            return
        }
        viewModel.hostNotice = nil
        let now = Date().timeIntervalSince1970
        let request: KeyboardLaunchRequest = if bridge.isModelInstalled {
            .startRecording(jobID: coldStartJobID, requestedAt: now, style: bridge.style, host: host)
        } else {
            .startSession(requestedAt: now, host: host)
        }
        bridge.ownFeedbackJob(coldStartJobID)
        ContainingAppOpener.open(request.url, from: self)
    }

    private func updateKeyboardTraits() {
        let globe = needsInputModeSwitchKey
        if viewModel.needsGlobeKey != globe {
            viewModel.needsGlobeKey = globe
        }
        // Fields that ask for a dark keyboard get one even in light mode, like the system keyboard.
        overrideUserInterfaceStyle = textDocumentProxy.keyboardAppearance == .dark ? .dark : .unspecified
        let nextReturn: String = switch textDocumentProxy.returnKeyType {
        case .send: "Send"
        case .google, .yahoo, .search: "Search"
        case .go: "Go"
        case .done: "Done"
        case .join: "Join"
        case .next: "Next"
        case .route: "Route"
        case .continue: "Continue"
        case .emergencyCall: "SOS"
        default: "Return"
        }
        if viewModel.returnKeyLabel != nextReturn {
            viewModel.returnKeyLabel = nextReturn
        }
    }

    private func startWarmDictation() {
        let now = Date().timeIntervalSince1970
        guard viewModel.hasFullAccess, viewModel.currentSnapshot.isAvailable(at: now) else { return }
        let jobID = UUID().uuidString
        ownedFeedbackJobs.insert(jobID)
        bridge.ownFeedbackJob(jobID)
        viewModel.dismissFeedback()
        viewModel.setPendingCommand(
            KeyboardViewModel.PendingCommand(kind: .start, jobID: jobID, sentAt: now),
            now: now,
            animated: true
        )
        // The text around the cursor and the host app, capped, as context for AI cleanup (Hex's
        // caret text). Only in the start command; cold starts open a URL and send no text.
        bridge.send(.start, jobID: jobID, style: viewModel.style, sentAt: now,
                    context: textDocumentProxy.documentContextBeforeInput,
                    selected: textDocumentProxy.selectedText,
                    after: textDocumentProxy.documentContextAfterInput,
                    host: KeyboardHost.app(of: self))
    }

    private func stopWarmDictation() {
        let now = Date().timeIntervalSince1970
        guard let jobID = viewModel.currentSnapshot.jobID ?? viewModel.pendingCommand?.jobID else { return }
        viewModel.setPendingCommand(
            KeyboardViewModel.PendingCommand(kind: .stop, jobID: jobID, sentAt: now),
            now: now,
            animated: true
        )
        bridge.send(.stop, jobID: jobID, style: viewModel.style, sentAt: now)
    }

    private func cancelWarmDictation() {
        let now = Date().timeIntervalSince1970
        guard let jobID = viewModel.currentSnapshot.jobID ?? viewModel.pendingCommand?.jobID else { return }
        viewModel.setPendingCommand(
            KeyboardViewModel.PendingCommand(kind: .cancel, jobID: jobID, sentAt: now),
            now: now,
            animated: true
        )
        bridge.send(.cancel, jobID: jobID, style: viewModel.style, sentAt: now)
    }
}
