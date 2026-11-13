import Foundation

/// HTTP directory browsing and byte transport. No playback or UI responsibilities.
final class HTTPFileService: @unchecked Sendable {
    let baseURL: URL
    private let network: BoundedHTTPClient
    init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        network = BoundedHTTPClient(baseURL: baseURL, username: username, password: password)
    }
    func close() { network.close() }
    deinit { network.close() }

    func url(path: String, directory: Bool = false) throws -> URL {
        let components = path.isEmpty ? [] : path.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw PlayerError("Invalid remote file path.")
        }
        var result = baseURL
        for component in components { result.appendPathComponent(component, isDirectory: false) }
        if directory, !result.absoluteString.hasSuffix("/") { result.appendPathComponent("") }
        guard network.contains(result) else { throw PlayerError("The file is outside this connection’s base URL.") }
        return result
    }

    private struct Item: Decodable {
        let name: String
        let size: Int64?
        let is_dir: Bool?
        let mod_time: String?
        // Also accept nginx's explicitly configured JSON autoindex format.
        let type: String?
        let mtime: String?
    }
    static func entries(data: Data, path: String) throws -> [BrowserEntry] {
        let items: [Item]
        do { items = try JSONDecoder().decode([Item]?.self, from: data) ?? [] }
        catch { throw PlayerError("The server did not return a supported JSON directory listing. Enable Caddy file_server browse.") }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        let httpDate = DateFormatter(); httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(secondsFromGMT: 0); httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        var seen = Set<String>()
        return try items.compactMap { item in
            let directory = item.is_dir ?? (item.type == "directory")
            var name = item.name
            if directory && name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
                  seen.insert(name).inserted, (item.size ?? 0) >= 0 else { throw PlayerError("The server returned an invalid directory entry.") }
            guard !name.hasPrefix(".") else { return nil }
            var entry = BrowserEntry(name: name, path: path.isEmpty ? name : path + "/" + name,
                directory: directory, size: directory ? 0 : item.size ?? 0)
            if let value = item.mod_time ?? item.mtime {
                entry.modified = (fractional.date(from: value) ?? standard.date(from: value) ?? httpDate.date(from: value))?.timeIntervalSince1970 ?? 0
            }
            return entry
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func readDirectory(path: String) async throws -> [BrowserEntry] {
        var request = URLRequest(url: try url(path: path, directory: true))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await network.perform(request, policy: .listing)
        return try Self.entries(data: response.data, path: path)
    }
    func attributes(path: String) async throws -> BrowserEntry {
        let folder = (path as NSString).deletingLastPathComponent
        guard let entry = try await readDirectory(path: folder).first(where: { $0.path == path && !$0.directory }) else {
            throw PlayerError("This file is no longer available in its folder.")
        }
        return entry
    }
    func readRange(path: String, size: Int64, range: Range<Int64>,
                   progress: @escaping @Sendable (Int64) -> Void) async throws -> Data {
        let request = Self.rangeRequest(url: try url(path: path), range: range)
        return try await network.perform(request, policy: .range(range, size: size, etag: nil, modified: nil),
                                         progress: progress).data
    }

    private static func rangeRequest(url: URL, range: Range<Int64>) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        return request
    }

    func openFile(path: String, size: Int64, cancellation: CancellationFlag) async throws -> CachedRemoteFile {
        guard size > 0, !cancellation.cancelled else {
            if cancellation.cancelled { throw CancellationError() }
            throw PlayerError("This file is empty or its size is unavailable.")
        }
        let fileURL = try url(path: path)
        let probe = Self.rangeRequest(url: fileURL, range: 0..<1)
        let first = try await network.perform(probe, policy: .range(0..<1, size: size, etag: nil, modified: nil), cancellation: cancellation)
        guard !cancellation.cancelled else { throw CancellationError() }
        let etag = first.response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let modified = first.response.value(forHTTPHeaderField: "Last-Modified")
        return CachedRemoteFile(size: size, cancellation: cancellation) { [self] range, _, _, completion in
            var request = Self.rangeRequest(url: fileURL, range: range)
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            else if let modified { request.setValue(modified, forHTTPHeaderField: "If-Unmodified-Since") }
            let task = network.start(request, policy: .range(range, size: size, etag: etag, modified: etag == nil ? modified : nil)) {
                completion($0.map(\.data))
            }
            return { task.cancel() }
        }
    }
}

struct HTTPResponse {
    let data: Data
    let response: HTTPURLResponse
}

enum HTTPReadPolicy {
    case listing
    case range(Range<Int64>, size: Int64, etag: String?, modified: String?)
    var maximumBytes: Int {
        switch self { case .listing: return 8 * 1024 * 1024
        case .range(let range, _, _, _): return Int(range.count) }
    }
    func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw HTTPStatusError(statusCode: response.statusCode) }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { throw PlayerError("The server returned encoded content instead of file bytes.") }
        switch self {
        case .listing:
            guard response.statusCode == 200 else { throw PlayerError("Directory request failed (HTTP \(response.statusCode)).") }
            guard response.mimeType?.lowercased() == "application/json" else { throw PlayerError("The server must return JSON for Accept: application/json.") }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw PlayerError("The directory listing exceeds 8 MiB.") }
        case .range(let range, let size, let etag, let modified):
            guard response.statusCode == 206 else {
                throw PlayerError("The server must support HTTP byte ranges (206 Partial Content). Full-file downloads are disabled (HTTP \(response.statusCode)).")
            }
            let expected = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            guard response.value(forHTTPHeaderField: "Content-Range") == expected,
                  response.expectedContentLength == -1 || response.expectedContentLength == Int64(maximumBytes) else {
                throw PlayerError("The server returned an incorrect byte range or the file changed.")
            }
            if let etag, response.value(forHTTPHeaderField: "ETag") != etag { throw PlayerError("The file changed during playback.") }
            if let modified, response.value(forHTTPHeaderField: "Last-Modified") != modified { throw PlayerError("The file changed during playback.") }
        }
    }
    func validateCount(_ count: Int) throws {
        if case .range = self, count != maximumBytes { throw PlayerError("The HTTP byte-range response ended early.") }
    }
}

private final class HTTPTaskSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func set(_ task: URLSessionDataTask) { lock.lock(); self.task = task; let stop = cancelled; lock.unlock(); if stop { task.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}

/// The delegate rejects invalid headers before allowing a body, then bounds every append.
/// URLCache, cookies and credential persistence are disabled; only our compressed cache retains media.
private final class BoundedHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer {
        let policy: HTTPReadPolicy
        let completion: @Sendable (Result<HTTPResponse, Error>) -> Void
        let progress: (@Sendable (Int64) -> Void)?
        var response: HTTPURLResponse?
        var data = Data()
        var error: Error?
        init(policy: HTTPReadPolicy, progress: (@Sendable (Int64) -> Void)?,
             completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) {
            self.policy = policy; self.progress = progress; self.completion = completion
        }
    }
    private let baseURL: URL
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!
    init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL; self.username = username; self.password = password
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    func contains(_ url: URL) -> Bool {
        url.scheme == baseURL.scheme && url.host?.lowercased() == baseURL.host?.lowercased() &&
        (url.port ?? (url.scheme == "https" ? 443 : 80)) == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)) &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        (url.path == baseURL.path || url.path.hasPrefix(baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/")) &&
        !url.path.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    func start(_ original: URLRequest, policy: HTTPReadPolicy,
               progress: (@Sendable (Int64) -> Void)? = nil,
               completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) -> URLSessionDataTask {
        var request = original
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !username.isEmpty || !password.isEmpty {
            request.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: request)
        lock.lock(); transfers[task.taskIdentifier] = Transfer(policy: policy, progress: progress, completion: completion); lock.unlock()
        task.resume()
        return task
    }
    func perform(_ request: URLRequest, policy: HTTPReadPolicy, cancellation: CancellationFlag? = nil,
                 progress: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPResponse {
        let slot = HTTPTaskSlot()
        let handler = cancellation?.onCancel { slot.cancel() }
        defer { if let handler { cancellation?.removeHandler(handler) } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                slot.set(start(request, policy: policy, progress: progress) { continuation.resume(with: $0) })
            }
        } onCancel: { slot.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let transfer = transfers[dataTask.taskIdentifier], let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            try transfer.policy.validate(response)
            transfer.response = response; completionHandler(.allow)
        } catch { transfer.error = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let transfer = transfers[dataTask.taskIdentifier], transfer.error == nil, transfer.response != nil else { return }
        guard data.count <= transfer.policy.maximumBytes - transfer.data.count else {
            transfer.error = PlayerError("The server exceeded the permitted response size."); dataTask.cancel(); return
        }
        transfer.data.append(data)
        transfer.progress?(Int64(transfer.data.count))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let transfer else { return }
        do {
            if let failure = transfer.error ?? error { throw failure }
            guard let response = transfer.response else { throw PlayerError("No HTTP response was received.") }
            try transfer.policy.validateCount(transfer.data.count)
            transfer.completion(.success(HTTPResponse(data: transfer.data, response: response)))
        } catch {
            if (error as? URLError)?.code == .cancelled { transfer.completion(.failure(CancellationError())) }
            else { transfer.completion(.failure(error)) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url, contains(url), (task.countOfBytesReceived == 0),
              let original = task.originalRequest else {
            transfers[task.taskIdentifier]?.error = PlayerError("The server redirected outside this connection’s base URL.")
            completionHandler(nil); return
        }
        var next = original; next.url = url
        completionHandler(next)
    }
}
