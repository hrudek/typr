import AVFAudio

/// The idle input must stay running for background keyboard dictation, but must not
/// keep another app interrupted. Change mixing options, never deactivate that input.
@MainActor
final class DictationAudioSession {
    private let setCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void
    private let setPreferredSampleRate: (Double) throws -> Void
    private let setActive: (Bool, AVAudioSession.SetActiveOptions) throws -> Void
    private(set) var isCapturing = false

    init(
        setCategory: @escaping (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void = {
            try AVAudioSession.sharedInstance().setCategory($0, mode: $1, options: $2)
        },
        setPreferredSampleRate: @escaping (Double) throws -> Void = {
            try AVAudioSession.sharedInstance().setPreferredSampleRate($0)
        },
        setActive: @escaping (Bool, AVAudioSession.SetActiveOptions) throws -> Void = {
            try AVAudioSession.sharedInstance().setActive($0, options: $1)
        }
    ) {
        self.setCategory = setCategory
        self.setPreferredSampleRate = setPreferredSampleRate
        self.setActive = setActive
    }

    func activate(allowBluetooth: Bool) throws {
        try configure(allowBluetooth: allowBluetooth)
        try setPreferredSampleRate(16_000)
        try setActive(true, [])
    }

    func beginCapture(allowBluetooth: Bool) throws {
        isCapturing = true
        do {
            try configure(allowBluetooth: allowBluetooth)
        } catch {
            isCapturing = false
            try? configure(allowBluetooth: allowBluetooth)
            // iOS can refuse to interrupt another app from the background ('!int').
            // Keep dictation working from the existing input in mixable mode instead.
        }
    }

    func endCapture(allowBluetooth: Bool) throws {
        isCapturing = false
        try configure(allowBluetooth: allowBluetooth)
    }

    func deactivate() {
        isCapturing = false
        try? setActive(false, .notifyOthersOnDeactivation)
    }

    func refresh(allowBluetooth: Bool) throws {
        try configure(allowBluetooth: allowBluetooth)
    }

    private func configure(allowBluetooth: Bool) throws {
        // playAndRecord otherwise defaults built-in playback to the quiet receiver.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if allowBluetooth { options.insert(.allowBluetoothHFP) }
        if !isCapturing { options.insert(.mixWithOthers) }
        // Keep category/mode and the input graph stable across capture boundaries.
        // Becoming mixable ends our interruption without stopping the warm microphone.
        try setCategory(.playAndRecord, .measurement, options)
    }
}
