import XCTest
@testable import Typr

struct TestStateTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Waits for a named state instead of a fixed delay. Returns as soon as the state holds; a
/// timeout fails and throws, so the test stops instead of asserting or tearing down files and
/// defaults while work is still running. The generous default only matters on failure: a cold
/// CI simulator can spend seconds in framework initialization before injected fakes run.
@MainActor
func waitForState(_ description: String, timeout: Duration = .seconds(10),
                  file: StaticString = #filePath, line: UInt = #line,
                  _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for: \(description)", file: file, line: line)
            throw TestStateTimeout(description: description)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Returns after every main-actor job enqueued before it has run (the main executor is a FIFO
/// serial queue). For hops whose correct effect is "nothing changed", e.g. a late progress update.
@MainActor
func mainActorBarrier() async {
    await Task { @MainActor in }.value
}

extension DictationController {
    /// Drain signal before teardown: no capture, permission request, transcription (including the
    /// unwind of a cancelled one) or cleanup job is left, and no phase is mid-work.
    var isIdleForTest: Bool { canChangeEngine && !phase.isBusy }
}
