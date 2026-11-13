import Foundation

@main struct ConnectionRetryTests {
    @MainActor static func main() async throws {
        var attempts = 0
        try await ConnectionRetry.run(delay: .zero) { number in
            attempts += 1
            if number == 1 { throw POSIXError(.EIO) }
        }
        precondition(attempts == 2)
        attempts = 0
        do {
            try await ConnectionRetry.run(delay: .zero) { _ in attempts += 1; throw POSIXError(.EIO) }
            preconditionFailure("A permanent I/O failure must be surfaced")
        } catch { precondition(attempts == 2 && (error as NSError).code == Int(POSIXErrorCode.EIO.rawValue)) }
        let networkFailures: [Error] = [POSIXError(.ECONNREFUSED), URLError(.cannotConnectToHost),
                                        URLError(.timedOut), URLError(.networkConnectionLost)]
        for failure in networkFailures {
            attempts = 0
            do {
                try await ConnectionRetry.run(delay: .zero) { _ in attempts += 1; throw failure }
                preconditionFailure("Expected the final connection error")
            } catch {
                precondition(attempts == 2 && (error as NSError) == (failure as NSError))
            }
        }
        precondition(!ConnectionRetry.isTransient(URLError(.serverCertificateUntrusted)))
        precondition(!ConnectionRetry.isTransient(URLError(.userAuthenticationRequired)))
        for code in [POSIXErrorCode.EACCES, .EPERM, .ENOENT, .EINVAL] {
            attempts = 0
            do {
                try await ConnectionRetry.run(delay: .zero) { _ in attempts += 1; throw POSIXError(code) }
                preconditionFailure("Expected failure")
            } catch { precondition(attempts == 1) }
        }
        let cancelled = Task { @MainActor in
            try await ConnectionRetry.run(delay: .seconds(30)) { _ in throw POSIXError(.EIO) }
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancellation must propagate") }
        catch is CancellationError { }
        print("PASS: transient connection recovery, two-attempt limit, no auth/path retries, cancellation propagation")
    }
}
