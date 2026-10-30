import Foundation

/// Retry only the read-only connection-opening operation, once, with a fresh SMB manager.
enum ConnectionRetry {
    static func isTransient(_ error: Error) -> Bool {
        let failure = error as NSError
        guard failure.domain == NSPOSIXErrorDomain else { return false }
        return [POSIXErrorCode.EIO, .ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE, .ETIMEDOUT]
            .contains { Int($0.rawValue) == failure.code }
    }
    @MainActor static func run(delay: Duration = .milliseconds(250), operation: (Int) async throws -> Void) async throws {
        for attempt in 1...2 {
            try Task.checkCancellation()
            do { try await operation(attempt); return }
            catch {
                guard attempt == 1, isTransient(error) else { throw error }
                try await Task.sleep(for: delay)
            }
        }
    }
}
