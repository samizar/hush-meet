import Foundation
import Testing
import MuesliCore

private actor Gate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite("Async deadlines")
struct DeadlineTests {
    @Test func returnsCompletedValue() async throws {
        #expect(try await AsyncDeadline.run(for: .seconds(1)) { 42 } == 42)
    }
    @Test func timeoutDoesNotWaitForUncooperativeWorker() async throws {
        let gate = Gate()
        let start = ContinuousClock.now
        await #expect(throws: AsyncDeadline.TimedOut.self) {
            try await AsyncDeadline.run(for: .milliseconds(30)) { await gate.wait(); return 42 }
        }
        #expect(start.duration(to: .now) < .seconds(1))
        // Also exercise a late completion after the continuation has already resumed.
        await gate.open()
    }
    @Test func cancellationDoesNotWaitForUncooperativeWorker() async throws {
        let gate = Gate()
        let task = Task { try await AsyncDeadline.run(for: .seconds(60)) { await gate.wait(); return 42 } }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open()
    }
    @Test func propagatesFailure() async {
        await #expect(throws: CocoaError.self) {
            try await AsyncDeadline.run(for: .seconds(1)) { throw CocoaError(.fileReadNoSuchFile) }
        }
    }
}
