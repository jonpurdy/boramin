import Foundation

/// Adapts callback APIs that do not propagate Swift task cancellation.
/// Cancellation releases the waiter once; a late callback only performs cleanup.
enum CancellableOperation {
    static func run<Value>(interrupt: @escaping @Sendable () -> Void,
                           start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let pending = Pending<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                start { result in
                    if pending.complete(result) { interrupt() }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            if pending.cancel() { interrupt() }
        }
    }

    private final class Pending<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var finished = false
        private var cancelled = false

        func install(_ value: CheckedContinuation<Value, Error>) -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock(); value.resume(throwing: CancellationError()); return false
            }
            continuation = value
            lock.unlock(); return true
        }
        /// Returns true for a late result from a cancelled operation.
        func complete(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard !finished else { let late = cancelled; lock.unlock(); return late }
            finished = true
            let value = continuation; continuation = nil
            lock.unlock()
            value?.resume(with: result)
            return false
        }
        func cancel() -> Bool {
            lock.lock()
            guard !finished else { lock.unlock(); return false }
            finished = true; cancelled = true
            let value = continuation; continuation = nil
            lock.unlock()
            value?.resume(throwing: CancellationError())
            return true
        }
    }
}
