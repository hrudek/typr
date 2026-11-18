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
        try session.activate(allowBluetooth: false, media: .pause)
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
        try session.activate(allowBluetooth: true, media: .pause)
        XCTAssertEqual(spy.categories, [.record])
        XCTAssertEqual(spy.options, [[.allowBluetoothHFP]])
    }

    func testReleaseNotifiesInterruptedAppsBeforeNextActivation() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false, media: .pause)
        session.deactivate()
        XCTAssertEqual(spy.activations, [true, false])
        XCTAssertEqual(spy.activationOptions.last, .notifyOthersOnDeactivation)
        try session.activate(allowBluetooth: false, media: .pause)
        XCTAssertEqual(spy.activations, [true, false, true])
        XCTAssertEqual(spy.options, [[], []])
    }

    func testKeepPlayingAndLowerVolumeMixWithoutDuckingWhileIdle() throws {
        for media in [MediaOnDictation.keepPlaying, .lowerVolume] {
            let spy = SessionSpy()
            try spy.makeSession().activate(allowBluetooth: true, media: media)
            XCTAssertEqual(spy.categories, [.playAndRecord], media.rawValue)
            XCTAssertEqual(spy.modes, [.measurement], media.rawValue)
            XCTAssertEqual(spy.options, [[.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]], media.rawValue)
            XCTAssertEqual(spy.activations, [true], media.rawValue)
        }
    }

    func testDuckingReactivatesAndOnlyDeactivationLiftsIt() throws {
        let spy = SessionSpy()
        let session = spy.makeSession()
        try session.activate(allowBluetooth: false, media: .lowerVolume)
        try session.duckOthers(allowBluetooth: false)
        XCTAssertEqual(spy.categories, [.playAndRecord, .playAndRecord])
        XCTAssertEqual(spy.options, [[.mixWithOthers, .defaultToSpeaker], [.duckOthers, .defaultToSpeaker]])
        XCTAssertEqual(spy.activations, [true, true])
        session.deactivate()
        XCTAssertEqual(spy.activations, [true, true, false])
        XCTAssertEqual(spy.activationOptions.last, .notifyOthersOnDeactivation)
        try session.activate(allowBluetooth: false, media: .lowerVolume)
        XCTAssertEqual(spy.options.count, 3)
        XCTAssertFalse(spy.options[2].contains(.duckOthers), "a new warm session must not duck")
    }

    func testConfigurationFailureDoesNotActivateAnUnknownSession() {
        let spy = SessionSpy()
        let session = spy.makeSession()
        spy.failCategory = true
        XCTAssertThrowsError(try session.activate(allowBluetooth: false, media: .pause))
        XCTAssertTrue(spy.activations.isEmpty)
    }
}
