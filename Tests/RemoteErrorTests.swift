import Foundation

@main struct RemoteErrorTests {
    static func main() {
        for code in [POSIXErrorCode.EPERM, .EACCES] {
            let error = POSIXError(code, userInfo: [NSLocalizedDescriptionKey: "Error code \(code.rawValue): "])
            precondition(RemoteErrorMessage.message(for: error).contains("server denied access"))
            precondition(!ConnectionRetry.isTransient(error))
        }
        precondition(RemoteErrorMessage.message(for: POSIXError(.ENOENT)).contains("couldn’t find"))
        precondition(RemoteErrorMessage.message(for: POSIXError(.EHOSTUNREACH)).contains("Couldn’t reach"))
        precondition(ConnectionRetry.isTransient(POSIXError(.ETIMEDOUT)))
        precondition(RemoteErrorMessage.message(for: URLError(.timedOut)).contains("didn’t respond"))
        precondition(RemoteErrorMessage.message(for: URLError(.serverCertificateUntrusted)).contains("certificate"))
        for (status, text) in [(401, "authentication"), (403, "denied"), (404, "couldn’t find"), (503, "Try again later")] {
            let message = RemoteErrorMessage.message(for: HTTPStatusError(statusCode: status))
            precondition(message.contains(text) && message.contains("HTTP \(status)"))
        }
        let validation = NSError(domain: "Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported directory listing."])
        precondition(RemoteErrorMessage.message(for: validation) == "Unsupported directory listing.")
        let empty = NSError(domain: NSPOSIXErrorDomain, code: 999, userInfo: [NSLocalizedDescriptionKey: ""])
        precondition(RemoteErrorMessage.message(for: empty).contains("couldn’t be completed"))
        print("PASS: remote error messages, structured codes, validation fallback, and retry classification")
    }
}
