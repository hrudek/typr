import SwiftUI
import Contacts

@main
struct TyprApp: App {
    @UIApplicationDelegateAdaptor(TyprAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = DictationController.shared
    @State private var openedFromKeyboard = Self.initialOpenedFromKeyboard
    @State private var showSetup = false
    @State private var setupRequestID: UUID?

    init() {
        FullKeyboardSettings().applyLaunchArguments()
    }

    private static var initialOpenedFromKeyboard: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--snap-state"), idx + 1 < args.count else {
            return false
        }
        return args[idx + 1].hasPrefix("handoff-")
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear
            } else if let keyboardScene = KeyboardSnapshotStage.requestedScene {
                KeyboardSnapshotStage(scene: keyboardScene)
            } else if let fullKeyboardScene = FullKeyboardSnapshotStage.requestedScene {
                FullKeyboardSnapshotStage(scene: fullKeyboardScene)
            } else if let hostedScene = HostedKeyboardConversationStage.requestedScene {
                HostedKeyboardConversationStage(scene: hostedScene, dictation: dictation)
            } else {
                ContentView(
                    dictation: dictation,
                    openedFromKeyboard: $openedFromKeyboard,
                    showSetup: $showSetup,
                    setupRequestID: setupRequestID
                )
                .task {
                    PersonalLexiconImporter.shared.refresh(force: true)
                    if scenePhase == .active { dictation.noteSceneDidBecomeActive() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    PersonalLexiconImporter.shared.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                    PersonalLexiconImporter.shared.refresh(force: true)
                }
                .onChange(of: DictationLogStore.shared.entries) { _, _ in
                    PersonalLexiconImporter.shared.refresh()
                }
                .onOpenURL { url in
                    // Typr: "Fix in Typr" from the keyboard opens the dictation log, not a session.
                    if TyprFeedbackRouter.shared.handle(url) {
                        openedFromKeyboard = false
                        return
                    }
                    guard let request = KeyboardLaunchRequest(url: url) else { return }
                    if case .setup = request {
                        openedFromKeyboard = false
                        showSetup = true
                        setupRequestID = UUID()
                    } else {
                        openedFromKeyboard = true
                    }
                    dictation.handleKeyboardLaunch(request)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        DictationLogStore.shared.purgeExpired()
                        PersonalLexiconImporter.shared.refresh(force: true)
                        dictation.noteSceneDidBecomeActive()
                    }
                    if phase == .background {
                        dictation.noteSceneDidEnterBackground()
                        openedFromKeyboard = false
                    }
                }
            }
        }
    }
}
