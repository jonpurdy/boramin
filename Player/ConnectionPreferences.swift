import Foundation
import Security
import CryptoKit
import Combine

struct SMBConnection: Identifiable, Equatable, Hashable {
    let id: String
    let server: String
    let username: String
    let domain: String
    let share: String
    let name: String
    let updated: Double
    var title: String { name.isEmpty ? (URL(string: server)?.host ?? server) : name }
    var detail: String { server + (share.isEmpty ? "" : "/" + share) + (username.isEmpty ? " · Guest" : " · " + username) }
    var fields: [String: String] {
        ["id": id, "server": server, "username": username, "domain": domain,
         "share": share, "name": name, "updated": String(updated)]
    }
    init?(id: String, fields: [String: String]) {
        guard !id.isEmpty, let address = fields["server"], let url = ConnectionPreferences.serverURL(address) else { return nil }
        self.id = id; server = url.absoluteString
        username = fields["username"] ?? ""; domain = fields["domain"] ?? ""
        share = fields["share"] ?? ""; name = fields["name"] ?? ""
        updated = fields["updated"].flatMap(Double.init) ?? 0
    }
}

@MainActor final class ConnectionPreferences: ObservableObject {
    static let shared = ConnectionPreferences()
    private let defaults: UserDefaults
    private let service: String
    @Published private(set) var connections: [SMBConnection] = []
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, service: String = "com.example.BoraMin.SMB") {
        self.defaults = defaults
        self.service = service
        migrateLegacyConnection()
        reload()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func query(server: URL, username: String, domain: String) -> [String: Any] {
        let identity = [server.host?.lowercased() ?? "", String(server.port ?? 445),
                        username.isEmpty ? "guest" : username, domain.lowercased()]
        let account = Data(identity.joined(separator: "\0").utf8).base64EncodedString()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func password(address: String, username: String, domain: String) -> String? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = URL(string: raw.contains("://") ? raw : "smb://\(raw)"),
              server.scheme == "smb", server.host != nil else { return nil }
        var request = query(server: server, username: username, domain: domain)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func profileID(server: URL, username: String, domain: String) -> String {
        let identity=[server.host?.lowercased() ?? "",String(server.port ?? 445),username.isEmpty ? "guest":username,domain.lowercased()]
        return SHA256.hash(data:Data(identity.joined(separator:"\0").utf8)).map { String(format:"%02x",$0) }.joined()
    }

    func storePassword(server: URL, username: String, domain: String, password: String) throws {
        let request = query(server: server, username: username, domain: domain)
        let data = Data(password.utf8)
        var status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo:
                [NSLocalizedDescriptionKey: "Could not save the connection password in Keychain (\(status))."])
        }
    }

    nonisolated static func serverURL(_ address: String) -> URL? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var parts = URLComponents(string: raw.contains("://") ? raw : "smb://" + raw),
              parts.scheme == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.host = host.lowercased(); if parts.port == 445 { parts.port = nil }; parts.path = ""
        return parts.url
    }
    var selected: SMBConnection? {
        let key = defaults.string(forKey: "selectedConnectionID")
        return connections.first { $0.id == key } ?? connections.first
    }
    func connection(id: String) -> SMBConnection? { connections.first { $0.id == id } }
    func resolve(id: String?, server: String, username: String? = nil, domain: String? = nil, share: String? = nil) -> SMBConnection? {
        if let id { return connection(id: id) }
        guard let url = Self.serverURL(server) else { return nil }
        var matches = connections.filter {
            $0.server == url.absoluteString && (username == nil || ($0.username.isEmpty ? "guest" : $0.username) == (username!.isEmpty ? "guest" : username!)) &&
                (domain == nil || $0.domain.lowercased() == domain!.lowercased())
        }
        if let share {
            let exact = matches.filter { $0.share.caseInsensitiveCompare(share) == .orderedSame }
            if !exact.isEmpty { matches = exact }
            else { matches = matches.filter { $0.share.isEmpty } }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func select(_ connection: SMBConnection) {
        defaults.set(connection.id, forKey: "selectedConnectionID")
        for key in ["server", "username", "domain", "share"] { defaults.set(connection.fields[key] ?? "", forKey: key) }
    }
    func save(server: URL, username: String, domain: String, share: String, password: String,
              id: String? = nil, name: String = "", select: Bool = true) throws {
        guard let url = Self.serverURL(server.absoluteString) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSValidationErrorMinimum, userInfo: [NSLocalizedDescriptionKey: "Enter an SMB server address without a share or credentials in the URL."])
        }
        try storePassword(server: url, username: username, domain: domain, password: password)
        var profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        let key = id ?? Self.profileID(server: url, username: username, domain: domain)
        let fields = ["id": key, "server": url.absoluteString, "username": username, "domain": domain,
                      "share": share, "name": name, "updated": String(Date().timeIntervalSince1970)]
        profiles[key] = fields
        defaults.set(profiles, forKey: "serverProfiles.v1")
        reload()
        if select || defaults.string(forKey: "selectedConnectionID") == key || connections.count == 1,
           let connection = connection(id: key) { self.select(connection) }
    }
    func delete(id: String) {
        var profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        guard profiles.removeValue(forKey: id) != nil else { return }
        defaults.set(profiles, forKey: "serverProfiles.v1")
        reload()
        // Keep other profiles using the same Keychain account, favorites and history.
        // Clear legacy selection fields so deleting the last profile cannot restore it.
        if connections.isEmpty {
            for key in ["selectedConnectionID", "server", "username", "domain", "share"] { defaults.removeObject(forKey: key) }
        } else if defaults.string(forKey: "selectedConnectionID") == id {
            select(connections[0])
        }
    }
    func applySyncedProfile(id: String, fields: [String: String], updated: Double, deleted: Bool) {
        guard updated.isFinite, SMBConnection(id: id, fields: fields) != nil else { return }
        if deleted { delete(id: id); return }
        var profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        var value = fields; value["id"] = id; value["updated"] = String(updated)
        profiles[id] = value
        if profiles != defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] {
            defaults.set(profiles, forKey: "serverProfiles.v1")
        }
    }
    func reload() {
        let profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        let saved = profiles.compactMap { SMBConnection(id: $0.key, fields: $0.value) }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if connections != saved { connections = saved }
        associateLegacyLocations()
    }
    private func migrateLegacyConnection() {
        guard !defaults.bool(forKey: "multipleConnectionsMigrated.v1") else { return }
        defer { defaults.set(true, forKey: "multipleConnectionsMigrated.v1") }
        var profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        if let url = Self.serverURL(defaults.string(forKey: "server") ?? "") {
            let user = defaults.string(forKey: "username") ?? "", domain = defaults.string(forKey: "domain") ?? ""
            let matches = profiles.filter { $0.value["server"].flatMap(Self.serverURL)?.absoluteString == url.absoluteString && ($0.value["username"] ?? "") == user && ($0.value["domain"] ?? "").lowercased() == domain.lowercased() }
            let key = matches.keys.sorted().first ?? Self.profileID(server: url, username: user, domain: domain)
            if profiles[key] == nil {
                profiles[key] = ["id": key, "server": url.absoluteString, "username": user, "domain": domain,
                                 "share": defaults.string(forKey: "share") ?? "", "updated": "0"]
                defaults.set(profiles, forKey: "serverProfiles.v1")
            }
            if defaults.string(forKey: "selectedConnectionID") == nil { defaults.set(key, forKey: "selectedConnectionID") }
        }
    }
    private func associateLegacyLocations() {
        // Attach IDs without changing existing favorite/Watching identities or timestamps.
        if let data = defaults.data(forKey: "favoriteLocations.v1"),
           var favorites = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
            var changed = false
            for index in favorites.indices where favorites[index]["connectionID"] == nil {
                let item = favorites[index]
                if let connection = resolve(id: nil, server: item["server"] ?? "", share: item["share"]) {
                    favorites[index]["connectionID"] = connection.id
                    favorites[index]["identity"] = [item["server"] ?? "", (item["share"] ?? "").lowercased(), item["path"] ?? ""].joined(separator: "\0")
                    changed = true
                }
            }
            if changed, let data = try? JSONSerialization.data(withJSONObject: favorites) { defaults.set(data, forKey: "favoriteLocations.v1") }
        }
        var files = defaults.dictionary(forKey: "playbackFiles.v1") as? [String: [String: String]] ?? [:]
        var changed = false
        for key in files.keys where files[key]?["connectionID"] == nil {
            let item = files[key]!
            if let connection = resolve(id: nil, server: item["server"] ?? "", username: item["username"], domain: item["domain"], share: item["share"]) {
                files[key]?["connectionID"] = connection.id; changed = true
            }
        }
        if changed { defaults.set(files, forKey: "playbackFiles.v1") }
    }
}
