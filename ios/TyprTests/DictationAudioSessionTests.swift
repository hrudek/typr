import AVFAudio
import XCTest
@testable import Typr

@MainActor
final class DictationAudioSessionTests: XCTestCase {
    private final class SessionSpy {
        var categories: [AVAudioSession.Category] = []
        var modes: [AVAudioSession.Mode] = []
        var options: [AVAudioSession.CategoryOptions] = []
        var activations: [Bool] = []
        var activationOptions: [AVAudioSession.SetActiveOptions] = []
        var sampleRates: [Double] = []
        var failNextCategoryChange = false

        func makeSession() -> DictationAudioSession {
            DictationAudioSession(setCategory: { category, mode, options in
                if self.failNextCategoryChange {
                    self.failNextCategoryChange = false
                    throw CocoaError(.coderInvalidValue)
                }
                self.categories.append(category)
                self.modes.append(mode)
                self.options.append(options)
            }, setPreferredSampleRate: {
                self.sampleRates.append($0)
            }, setActive: { active, options in
                self.activations.append(active)
                self.activationOptions.append(options)
            })
        }
    }

    func testWarmInputMixesButEachCaptureInterruptsUntilStopped() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        for _ in 0..<2 {
            try session.beginCapture(allowBluetooth: false)
            XCTAssertTrue(session.isCapturing)
            try session.endCapture(allowBluetooth: false)
            XCTAssertFalse(session.isCapturing)
        }
        XCTAssertEqual(spy.options, [.mixWithOthers, [], .mixWithOthers, [], .mixWithOthers])
        XCTAssertTrue(spy.categories.allSatisfy { $0 == .playAndRecord })
        XCTAssertTrue(spy.modes.allSatisfy { $0 == .measurement })
        XCTAssertEqual(spy.sampleRates, [16_000])
        // No deactivation/reactivation at capture boundaries: input must survive in background.
        XCTAssertEqual(spy.activations, [true])
    }

    func testBluetoothOptionSurvivesCaptureAndRelease() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: true)
        try session.beginCapture(allowBluetooth: true)
        try session.endCapture(allowBluetooth: true)
        XCTAssertEqual(spy.options, [
            [.allowBluetoothHFP, .mixWithOthers], [.allowBluetoothHFP],
            [.allowBluetoothHFP, .mixWithOthers],
        ])
    }

    func testReactivationDuringCaptureDoesNotReleaseInterruption() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        try session.beginCapture(allowBluetooth: false)
        try session.activate(allowBluetooth: false)
        XCTAssertEqual(spy.options.last, [])
        XCTAssertTrue(session.isCapturing)
    }

    func testFailedCaptureStartRestoresMixing() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        spy.failNextCategoryChange = true
        XCTAssertThrowsError(try session.beginCapture(allowBluetooth: false))
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(spy.options.last, .mixWithOthers)
    }

    func testFailedReleaseCanBeRetriedWithoutRestartingInput() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        try session.beginCapture(allowBluetooth: false)
        spy.failNextCategoryChange = true
        XCTAssertThrowsError(try session.endCapture(allowBluetooth: false))
        XCTAssertFalse(session.isCapturing)
        try session.refresh(allowBluetooth: false)
        XCTAssertEqual(spy.options.last, .mixWithOthers)
        XCTAssertEqual(spy.activations, [true])
    }

    func testEndingSessionNotifiesInterruptedAppsAndResetsCaptureState() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        try session.beginCapture(allowBluetooth: false)
        session.deactivate()
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(spy.activations, [true, false])
        XCTAssertEqual(spy.activationOptions.last, .notifyOthersOnDeactivation)
        try session.activate(allowBluetooth: false)
        XCTAssertEqual(spy.options.last, .mixWithOthers)
    }
}
