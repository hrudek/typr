import XCTest
@testable import Typr

@MainActor
final class KeyboardBridgeTests: XCTestCase {
    func testSnapshotAvailabilityRequiresFreshHeartbeatAndActiveSession() {
        let now = 1_000.0
        let available = snapshot(state: .ready, heartbeat: now - 2.9, expiresAt: now + 1)
        let stale = snapshot(state: .ready, heartbeat: now - 3.0, expiresAt: now + 1)
        let expired = snapshot(state: .ready, heartbeat: now, expiresAt: now)
        let transcribingAfterSessionEnd = snapshot(state: .transcribing, heartbeat: now - 0.5, expiresAt: 0)

        XCTAssertTrue(available.isAvailable(at: now))
        XCTAssertFalse(stale.isAvailable(at: now))
        XCTAssertFalse(expired.isAvailable(at: now))
        XCTAssertTrue(transcribingAfterSessionEnd.isAvailable(at: now))
    }

    func testWarmDurationPersistsAndUnknownValueFallsBack() {
        let suite = "typr.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = KeyboardBridge(defaults: defaults)

        bridge.warmDuration = .oneHour
        XCTAssertEqual(defaults.string(forKey: "settings.warmDuration"), "oneHour")
        XCTAssertEqual(KeyboardBridge(defaults: defaults).warmDuration, .oneHour)

        defaults.set("always", forKey: "settings.warmDuration")
        XCTAssertEqual(bridge.warmDuration, .fifteenMinutes)
    }

    func testDeliverableResultSurvivesWarmSessionShutdownUntilTTL() {
        let now = 5_000.0
        let closedWithResult = KeyboardSnapshot(
            state: .offline,
            heartbeat: 0,
            expiresAt: 0,
            resultID: "res-1",
            resultExpiresAt: now + 25,
            transcript: "Ship it."
        )
        XCTAssertFalse(closedWithResult.isAvailable(at: now))
        XCTAssertTrue(closedWithResult.hasDeliverableResult(at: now))
        XCTAssertFalse(closedWithResult.hasDeliverableResult(at: now + 26))
    }

    func testKeyboardMessagesRoundTripThroughJSON() throws {
        let command = KeyboardCommand(
            id: "command",
            kind: .stop,
            jobID: "job",
            style: .casual,
            sentAt: 42.5
        )
        let snap = snapshot(state: .recording, heartbeat: 10, expiresAt: 20)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(KeyboardCommand.self, from: encoder.encode(command)),
            command
        )
        XCTAssertEqual(
            try decoder.decode(KeyboardSnapshot.self, from: encoder.encode(snap)),
            snap
        )
    }

    func testKeyboardRecordingLaunchRoundTripsMetadataAndEnforcesTenSecondWindow() {
        let t0 = 2_000.0
        let request = KeyboardLaunchRequest.startRecording(
            jobID: "job with spaces",
            requestedAt: t0,
            style: .casual,
            host: "com.openai.chat"
        )

        let decoded = KeyboardLaunchRequest(url: request.url)
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(request.isHandoffExpired(at: t0 + 9.9))
        XCTAssertTrue(request.isHandoffExpired(at: t0 + 10.1))
    }

    func testKeyboardSessionLaunchDoesNotRequestRecording() {
        let request = KeyboardLaunchRequest.startSession(requestedAt: 100, host: "com.apple.MobileSMS")
        XCTAssertEqual(KeyboardLaunchRequest(url: request.url), request)
        XCTAssertEqual(request.host, "com.apple.MobileSMS")
    }

    func testKeyboardSetupLaunchRoundTripsWithoutAHandoff() {
        let request = KeyboardLaunchRequest.setup
        XCTAssertEqual(request.url.absoluteString, "typr://keyboard/setup")
        XCTAssertEqual(KeyboardLaunchRequest(url: request.url), request)
        XCTAssertFalse(request.isHandoffExpired(at: 1_000_000))
    }

    @MainActor
    func testFullAccessSeenAtIsStoredInTheAppGroup() {
        let suiteName = "typr.tests.fullAccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bridge = KeyboardBridge(defaults: defaults)

        XCTAssertNil(bridge.fullAccessSeenAt)
        bridge.fullAccessSeenAt = 1_234
        XCTAssertEqual(KeyboardBridge(defaults: defaults).fullAccessSeenAt, 1_234)
    }

    func testKeyboardRecordingLaunchRequiresAJob() {
        let url = URL(string: "typr://keyboard/record")!
        XCTAssertNil(KeyboardLaunchRequest(url: url))
    }

    func testTranscriptStylesFormatDeterministically() {
        let raw = "um let's ship the ios build tonight"
        XCTAssertEqual(
            TranscriptFormatter.format(raw, style: .polished),
            "Let's ship the ios build tonight."
        )
        XCTAssertEqual(
            TranscriptFormatter.format("Um, Sounds Good.", style: .veryCasual),
            "sounds good"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("um keep raw words", style: .verbatim),
            "um keep raw words"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("First item bullet check signing bullet test keyboard", style: .notes),
            "First item\n- Check signing\n- Test keyboard"
        )
    }

    func testSmartInsertionSpacingRespectsSurroundingContext() {
        XCTAssertEqual(
            TranscriptFormatter.insertionText(for: "world.", beforeContext: "Hello", afterContext: nil),
            " world."
        )
        XCTAssertEqual(
            TranscriptFormatter.insertionText(for: "world.", beforeContext: "Hello ", afterContext: nil),
            "world."
        )
        XCTAssertEqual(
            TranscriptFormatter.insertionText(for: "Hello", beforeContext: nil, afterContext: "world"),
            "Hello "
        )
    }

    func testAppIntentMetadataContainsNoApplePlatformNames() throws {
        var texts = [
            String(localized: DictateWithTyprIntent.title),
            String(localized: WarmTyprKeyboardIntent.title),
            String(localized: ToggleTyprControlIntent.title),
            String(localized: StopTyprDictationIntent.title),
            String(localized: CancelTyprDictationIntent.title),
            String(localized: DictateWithTyprIntent.description.descriptionText),
            String(localized: WarmTyprKeyboardIntent.description.descriptionText),
            String(localized: ToggleTyprControlIntent.description.descriptionText),
            String(localized: StopTyprDictationIntent.description.descriptionText),
            String(localized: CancelTyprDictationIntent.description.descriptionText),
        ]

        // Read user-facing strings from compiled Metadata.appintents inside Typr.app and TyprWidgets.appex,
        // plus source literals when #filePath is not CAS prefix-mapped (/^wt).
        let userKeys: Set<String> = ["title", "shortTitle", "description", "key", "phrases", "basePhrases", "template"]
        func collectUserStrings(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict {
                    if userKeys.contains(k) {
                        if let s = v as? String {
                            texts.append(s)
                        } else if let arr = v as? [String] {
                            texts.append(contentsOf: arr)
                        } else {
                            collectUserStrings(v)
                        }
                    } else {
                        collectUserStrings(v)
                    }
                }
            } else if let arr = node as? [Any] {
                for item in arr {
                    collectUserStrings(item)
                }
            }
        }

        var metadataFilesRead = 0
        var metadataRoots: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents"),
        ]
        if let plugIns = Bundle.main.builtInPlugInsURL {
            metadataRoots.append(
                plugIns.appendingPathComponent("TyprWidgets.appex/Metadata.appintents")
            )
        }
        for root in metadataRoots where FileManager.default.fileExists(atPath: root.path) {
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    guard ["json", "actionsdata", "phrasesdata"].contains(url.pathExtension),
                          let data = try? Data(contentsOf: url),
                          let obj = try? JSONSerialization.jsonObject(with: data) else {
                        continue
                    }
                    metadataFilesRead += 1
                    collectUserStrings(obj)
                }
            }
        }
        XCTAssertGreaterThan(metadataFilesRead, 0, "Expected compiled Metadata.appintents in host bundle")

        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: ios.appendingPathComponent("Typr/TyprIntents.swift").path) {
            for file in [
                "Typr/TyprIntents.swift",
                "TyprActivity/TyprActivityAttributes.swift",
                "TyprActivity/TyprControlIntents.swift",
                "TyprWidgets/TyprDictationControl.swift",
            ] {
                let source = try String(contentsOf: ios.appendingPathComponent(file), encoding: .utf8)
                for line in source.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    texts.append(contentsOf: line.split(separator: "\"", omittingEmptySubsequences: false)
                        .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) })
                }
            }
        }

        let forbidden = ["iphone", "ipad", "apple", "siri", "macos", "ios", "watch", "airpods", "vision"]
        for text in texts {
            let lower = text.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word), "Intent string '\(text)' contains forbidden word '\(word)'")
            }
        }
    }

    private func snapshot(
        state: KeyboardDictationState,
        heartbeat: TimeInterval,
        expiresAt: TimeInterval
    ) -> KeyboardSnapshot {
        KeyboardSnapshot(
            state: state,
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            recordingStartedAt: heartbeat - 2,
            audioLevel: 0.5,
            jobID: "job",
            resultID: "result",
            resultExpiresAt: heartbeat + 30,
            transcript: "hello",
            message: nil
        )
    }
}
