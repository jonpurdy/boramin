import Foundation

/// Keep HTTP status structured; never retain response bodies, URLs or credentials here.
struct HTTPStatusError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "The HTTP request failed (HTTP \(statusCode))." }
}

/// Presentation only: callers retain the original errors for retry and cancellation decisions.
enum RemoteErrorMessage {
    static func message(for error: Error) -> String {
        let failure = error as NSError
        var explanation: String?
        var details: String?
        if let http = error as? HTTPStatusError {
            details = "HTTP \(http.statusCode)"
            switch http.statusCode {
            case 401: explanation = "The server requires authentication. Check your username and password."
            case 403: explanation = denied
            case 404, 410: explanation = missing
            case 408, 504: explanation = timeout
            case 412: explanation = "The file changed on the server. Refresh its folder and try again."
            case 416: explanation = "The server couldn’t provide the requested part of this file. Refresh its folder and try again."
            case 429: explanation = "The server is receiving too many requests. Wait a moment and try again."
            case 500...599: explanation = "The server couldn’t complete the request. Try again later."
            default: explanation = "The server returned an unexpected response. Check the server configuration."
            }
        } else if failure.domain == NSPOSIXErrorDomain {
            details = "SMB/POSIX error \(failure.code)"
            switch Int32(failure.code) {
            case EPERM, EACCES: explanation = denied
            case ENOENT: explanation = missing
            case ETIMEDOUT: explanation = timeout
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: explanation = unreachable
            case ECONNREFUSED: explanation = "The server refused the connection. Check that file sharing is enabled and the server address and port are correct."
            case ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN, ENETRESET, ENOLINK: explanation = lost
            case EROFS: explanation = "This location is read-only. Check the server’s sharing settings and drive permissions."
            case ENOSPC: explanation = "The server has no space available. Free space on the destination drive and try again."
            default: break
            }
        } else if failure.domain == NSURLErrorDomain {
            details = "Network error \(failure.code)"
            switch URLError.Code(rawValue: failure.code) {
            case .timedOut: explanation = timeout
            case .cannotFindHost, .dnsLookupFailed: explanation = "Couldn’t find the server. Check its name or try its IP address."
            case .cannotConnectToHost, .notConnectedToInternet: explanation = unreachable
            case .networkConnectionLost: explanation = lost
            case .userAuthenticationRequired, .userCancelledAuthentication: explanation = "The server requires authentication. Check your username and password."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                explanation = "Couldn’t establish a secure connection. Check the server’s HTTPS certificate and your device’s date and time."
            default: explanation = "The network request failed. Check your connection and try again."
            }
        }
        if let explanation { return explanation + (details.map { "\n\n\($0)" } ?? "") }
        // Preserve existing validation messages and meaningful library descriptions.
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty, description != "Error code \(failure.code):" { return description }
        return "The operation couldn’t be completed. Try again. If it continues, check the server." +
            (details.map { "\n\n\($0)" } ?? "")
    }

    private static let denied = "The server denied access. Check your username, password, domain, and permissions for this location."
    private static let missing = "The server couldn’t find this share, folder, or file. It may be temporarily unavailable. Refresh and try again; check that the shared folder and its drive are available on the server."
    private static let timeout = "The server didn’t respond in time. Check that it’s awake and reachable, then try again."
    private static let lost = "The connection to the server was lost. Try reconnecting."
    private static var unreachable: String {
        var message = "Couldn’t reach the server. Check your network connection and server address."
        #if os(iOS)
        message += " Also check BoraMin’s access in Settings → Privacy & Security → Local Network."
        #elseif os(macOS)
        message += " Also check BoraMin’s access in System Settings → Privacy & Security → Local Network."
        #endif
        return message
    }
}
