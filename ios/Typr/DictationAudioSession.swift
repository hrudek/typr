import AVFAudio

/// Keep the proven input-only session stable for the lifetime of the input graph.
/// The controller decides whether to retain it or fully deactivate after capture.
@MainActor
final class DictationAudioSession {
    private let setCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void
    private let setPreferredSampleRate: (Double) throws -> Void
    private let setActive: (Bool, AVAudioSession.SetActiveOptions) throws -> Void

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

    /// Pause interrupts other audio. The other choices mix with it; `.record` cannot mix, and
    /// `.defaultToSpeaker` keeps other apps' playback off the receiver under `.playAndRecord`.
    func activate(allowBluetooth: Bool, media: MediaOnDictation) throws {
        let bluetooth: AVAudioSession.CategoryOptions = allowBluetooth ? [.allowBluetoothHFP] : []
        if media == .pause {
            try setCategory(.record, .measurement, bluetooth)
        } else {
            try setCategory(.playAndRecord, .measurement, bluetooth.union([.mixWithOthers, .defaultToSpeaker]))
        }
        try setPreferredSampleRate(16_000)
        try setActive(true, [])
    }

    /// iOS applies ducking on activation and lifts it only on deactivation, so the caller
    /// must `deactivate()` to restore the other app's volume.
    func duckOthers(allowBluetooth: Bool) throws {
        let bluetooth: AVAudioSession.CategoryOptions = allowBluetooth ? [.allowBluetoothHFP] : []
        try setCategory(.playAndRecord, .measurement, bluetooth.union([.duckOthers, .defaultToSpeaker]))
        try setActive(true, [])
    }

    func deactivate() {
        try? setActive(false, .notifyOthersOnDeactivation)
    }
}
