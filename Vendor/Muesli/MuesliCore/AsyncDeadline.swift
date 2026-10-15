import Foundation
import os

public enum AsyncDeadline {
    public struct TimedOut: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The operation took too long. Your saved recording has been kept; try again." }
        public init() {}
    }

    /// Unlike a task-group race, this returns on timeout even if a system API ignores cancellation.
    /// Callers must arrange cancellation of external resources and ignore any late callbacks.
    public static func run<Value: Sendable>(for limit: Duration, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let worker = Task {
                    do { try Task.checkCancellation(); race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: limit); race.finish(.failure(TimedOut())) }
                    catch { /* Winner or caller cancelled the timer. */ }
                }
                race.setTasks(worker, timer)
            }
        } onCancel: { race.finish(.failure(CancellationError())) }
    }

    private final class Race<Value: Sendable>: Sendable {
        private struct State {
            var result: Result<Value, Error>?
            var continuation: CheckedContinuation<Value, Error>?
            var tasks: [Task<Void, Never>] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let result = state.withLock { value -> Result<Value, Error>? in
                if let result = value.result { return result }
                value.continuation = continuation; return nil
            }
            if let result { continuation.resume(with: result) }
        }
        func setTasks(_ worker: Task<Void, Never>, _ timer: Task<Void, Never>) {
            let finished = state.withLock { value in
                guard value.result == nil else { return true }
                value.tasks = [worker, timer]; return false
            }
            if finished { worker.cancel(); timer.cancel() }
        }
        func finish(_ result: Result<Value, Error>) {
            let completion = state.withLock { value -> (CheckedContinuation<Value, Error>?, [Task<Void, Never>])? in
                guard value.result == nil else { return nil }
                value.result = result
                let completion = (value.continuation, value.tasks)
                value.continuation = nil; value.tasks = []
                return completion
            }
            guard let completion else { return }
            for task in completion.1 { task.cancel() }
            completion.0?.resume(with: result)
        }
    }
}
