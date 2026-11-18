import AVFAudio
import XCTest
@testable import Typr

@MainActor
final class DictationAudioSessionTests: XCTestCase {
    @MainActor
    private final class SessionSpy {
        var categories: [AVAudioSession.Category] = []
        var modes: [AVAudioSession.Mode] = []
        var options: [AVAudioSession.CategoryOptions] = []
        var activations: [Bool] = []
        var activationOptions: [AVAudioSession.SetActiveOptions] = []
        var sampleRates: [Double] = []
        var failCategory = false

        func makeSession() -> DictationAudioSession {
            DictationAudioSession(setCategory: { category, mode, options in
                if self.failCategory { throw CocoaError(.coderInvalidValue) }
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

    func testActivationUsesProvenInputOnlyMeasurementSession() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        XCTAssertEqual(spy.categories, [.record])
        XCTAssertEqual(spy.modes, [.measurement])
        XCTAssertEqual(spy.options, [[]])
        XCTAssertEqual(spy.sampleRates, [16_000])
        XCTAssertEqual(spy.activations, [true])
        XCTAssertEqual(spy.activationOptions, [[]])
    }

    func testBluetoothIsTheOnlyOptionalCategoryFlag() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: true)
        XCTAssertEqual(spy.categories, [.record])
        XCTAssertEqual(spy.options, [[.allowBluetoothHFP]])
    }

    func testReleaseNotifiesInterruptedAppsBeforeNextActivation() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false)
        session.deactivate()
        XCTAssertEqual(spy.activations, [true, false])
        XCTAssertEqual(spy.activationOptions.last, .notifyOthersOnDeactivation)
        try session.activate(allowBluetooth: false)
        XCTAssertEqual(spy.activations, [true, false, true])
        XCTAssertEqual(spy.options, [[], []])
    }

    func testConfigurationFailureDoesNotActivateAnUnknownSession() {
        let spy = SessionSpy()
        let session = spy.makeSession()
        spy.failCategory = true
        XCTAssertThrowsError(try session.activate(allowBluetooth: false))
        XCTAssertTrue(spy.activations.isEmpty)
    }
}
