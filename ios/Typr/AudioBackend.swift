import AVFAudio
import Foundation

nonisolated enum AudioSystemEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeOldDeviceUnavailable
    case routeNewDeviceAvailable
    case mediaServicesReset
}

@MainActor
protocol ActiveAudioCapture: AnyObject {
    var url: URL { get }
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func normalizedPowerLevel() -> Float
    func averagePowerDB() -> Float
    func stop()
}

extension ActiveAudioCapture {
    func averagePowerDB() -> Float {
        DotScopeSimulation.loudness(fromNormalized: normalizedPowerLevel())
    }
}

@MainActor
protocol AudioManaging: AnyObject {
    var isKeepaliveRunning: Bool { get }
    var isOtherAudioPlaying: Bool { get }
    var onSystemEvent: ((AudioSystemEvent) -> Void)? { get set }
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)? { get set }

    func requestPermission() async -> Bool
    func startKeepalive(allowBluetooth: Bool) throws
    /// Starts the keepalive only when it isn't already running with these options and the
    /// current media choice. Never
    /// restarts a running input: iOS refuses to start microphone input in the background,
    /// so a restart there would end the warm session.
    func ensureKeepalive(allowBluetooth: Bool) throws
    func stopKeepalive()
    func deactivateSession()
    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture
    /// Applies to the next `startKeepalive`; `ensureKeepalive` restarts input started with another choice.
    func setMediaOnDictation(_ media: MediaOnDictation)
    /// Lowers other audio until `deactivateSession()`.
    func duckOthers(allowBluetooth: Bool) throws
}

extension AudioManaging {
    var isOtherAudioPlaying: Bool { false }
    func setMediaOnDictation(_ media: MediaOnDictation) {}
    func duckOthers(allowBluetooth: Bool) throws {}

    func ensureKeepalive(allowBluetooth: Bool) throws {
        guard !isKeepaliveRunning else { return }
        try startKeepalive(allowBluetooth: allowBluetooth)
    }
}

/// Writes the running input tap into a 16 kHz mono 16-bit WAV (the format the recorder used to
/// write). Called on the tap's thread; everything is guarded by `lock`.
nonisolated private final class TapFileWriter: @unchecked Sendable {
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
    }

    /// Called once, off the main thread, when the writer ends by itself: `true` at the
    /// duration limit, `false` when writing failed.
    var onEnd: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let maxFrames: AVAudioFramePosition
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var powerDB: Float = -160
    private var isOpen = true

    init(url: URL, maxDuration: TimeInterval) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        outputFormat = format
        maxFrames = AVAudioFramePosition(maxDuration * format.sampleRate)
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    var currentTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / outputFormat.sampleRate
    }

    var averagePowerDB: Float {
        lock.lock()
        defer { lock.unlock() }
        return powerDB
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var ended: Bool?
        lock.lock()
        if isOpen, let file {
            do {
                if let converted = try convert(buffer) {
                    let remaining = max(0, maxFrames - framesWritten)
                    if AVAudioFramePosition(converted.frameLength) > remaining {
                        converted.frameLength = AVAudioFrameCount(remaining)
                    }
                    if converted.frameLength > 0 {
                        try file.write(from: converted)
                        framesWritten += AVAudioFramePosition(converted.frameLength)
                        powerDB = Self.powerDB(of: converted)
                    }
                }
                if framesWritten >= maxFrames {
                    closeLocked()
                    ended = true
                }
            } catch {
                closeLocked()
                ended = false
            }
        }
        let onEnd = self.onEnd
        lock.unlock()
        if let ended {
            onEnd?(ended)
        }
    }

    /// Closing releases the file, which finishes its WAV header.
    func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func closeLocked() {
        isOpen = false
        file = nil
        converter = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { throw CocoaError(.coderInvalidValue) }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CocoaError(.coderInvalidValue)
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? CocoaError(.fileWriteUnknown)
        }
        return output
    }

    private static func powerDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        guard rms > 0 else { return -160 }
        return max(-160, 20 * log10(rms))
    }
}

/// Hands the keepalive tap's buffers to the capture currently writing, if any.
nonisolated private final class TapRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: TapFileWriter?

    func attach(_ newWriter: TapFileWriter) {
        lock.lock()
        let previous = writer
        writer = newWriter
        lock.unlock()
        if let previous, previous !== newWriter {
            previous.close()
        }
    }

    func detach(_ oldWriter: TapFileWriter) {
        lock.lock()
        if writer === oldWriter {
            writer = nil
        }
        lock.unlock()
    }

    func route(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = writer
        lock.unlock()
        current?.append(buffer)
    }
}

/// A capture that records from the already running keepalive input. Stopping it leaves the
/// input running, so a warm session never has to start the microphone again in the background.
@MainActor
private final class TapCaptureAdapter: ActiveAudioCapture {
    let url: URL
    private let writer: TapFileWriter
    private let router: TapRouter
    private let onFinish: @MainActor (URL, Bool) -> Void
    private var stopped = false

    init(
        url: URL,
        writer: TapFileWriter,
        router: TapRouter,
        onFinish: @escaping @MainActor (URL, Bool) -> Void
    ) {
        self.url = url
        self.writer = writer
        self.router = router
        self.onFinish = onFinish
    }

    var isRecording: Bool {
        !stopped && writer.isRecording
    }

    var currentTime: TimeInterval {
        writer.currentTime
    }

    func averagePowerDB() -> Float {
        writer.averagePowerDB
    }

    func normalizedPowerLevel() -> Float {
        max(0, min(1, (averagePowerDB() + 48) / 48))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        router.detach(writer)
        writer.close()
    }

    func writerEnded(succeeded: Bool) {
        guard !stopped else { return }
        stopped = true
        router.detach(writer)
        onFinish(url, succeeded)
    }
}

@MainActor
final class SystemAudioManager: AudioManaging {
    private var inputGraph = TyprAudioInput()
    private let audioSession = DictationAudioSession()
    private var keepaliveAllowsBluetooth: Bool?
    private var keepaliveMedia: MediaOnDictation?
    private var mediaOnDictation = MediaOnDictation.pause
    private let tapRouter = TapRouter()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?

    var isKeepaliveRunning: Bool {
        inputGraph.isRunning
    }

    var isOtherAudioPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    init() {
        installNotifications()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startKeepalive(allowBluetooth: Bool) throws {
        stopKeepalive()
        try audioSession.activate(allowBluetooth: allowBluetooth, media: mediaOnDictation)

        try inputGraph.start(bufferHandler: Self.tapBlock(routingTo: tapRouter))
        keepaliveAllowsBluetooth = allowBluetooth
        keepaliveMedia = mediaOnDictation
    }

    func ensureKeepalive(allowBluetooth: Bool) throws {
        if inputGraph.isRunning, keepaliveAllowsBluetooth == allowBluetooth, keepaliveMedia == mediaOnDictation {
            return
        }
        try startKeepalive(allowBluetooth: allowBluetooth)
    }

    func stopKeepalive() {
        keepaliveAllowsBluetooth = nil
        keepaliveMedia = nil
        inputGraph.stop()
    }

    func deactivateSession() {
        stopKeepalive()
        audioSession.deactivate()
    }

    func setMediaOnDictation(_ media: MediaOnDictation) {
        mediaOnDictation = media
    }

    func duckOthers(allowBluetooth: Bool) throws {
        try audioSession.duckOthers(allowBluetooth: allowBluetooth)
    }

    func beginCapture(
        at url: URL,
        maxDuration: TimeInterval,
        allowBluetooth: Bool
    ) throws -> any ActiveAudioCapture {
        // Record from the keepalive input instead of switching to a recorder: stopping the
        // input after a capture and starting it again fails while Typr is in the background,
        // which ended the warm session after every keyboard dictation.
        try ensureKeepalive(allowBluetooth: allowBluetooth)

        let writer = try TapFileWriter(url: url, maxDuration: maxDuration)
        let capture = TapCaptureAdapter(url: url, writer: writer, router: tapRouter) { [weak self] finishedURL, ok in
            self?.onUnexpectedCaptureEnd?(finishedURL, ok)
        }
        writer.onEnd = { [weak capture] succeeded in
            Task { @MainActor in
                capture?.writerEnded(succeeded: succeeded)
            }
        }
        tapRouter.attach(writer)
        return capture
    }

    /// Built outside the main actor so the tap thread never runs a main-actor closure.
    nonisolated private static func tapBlock(routingTo router: TapRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            router.route(buffer)
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self,
                          let typeRaw,
                          let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
                        return
                    }
                    switch type {
                    case .began:
                        self.onSystemEvent?(.interruptionBegan)
                    case .ended:
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
                        self.onSystemEvent?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                    @unknown default:
                        break
                    }
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self,
                          let reasonRaw,
                          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
                        return
                    }
                    switch reason {
                    case .oldDeviceUnavailable:
                        self.onSystemEvent?(.routeOldDeviceUnavailable)
                    case .newDeviceAvailable:
                        self.onSystemEvent?(.routeNewDeviceAvailable)
                    default:
                        break
                    }
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inputGraph.stop()
                    self.inputGraph = TyprAudioInput()
                    self.onSystemEvent?(.mediaServicesReset)
                }
            }
        )
    }
}
