import Foundation
import Security
import CryptoKit

@MainActor final class ConnectionPreferences {
    static let shared = ConnectionPreferences()
    private let defaults: UserDefaults
    private let service: String

    init(defaults: UserDefaults = .standard, service: String = "com.example.BoraMin.SMB") {
        self.defaults = defaults
        self.service = service
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

    func save(server: URL, username: String, domain: String, share: String, password: String) throws {
        try storePassword(server:server,username:username,domain:domain,password:password)
        var profiles=defaults.dictionary(forKey:"serverProfiles.v1") as? [String:[String:String]] ?? [:]
        profiles[Self.profileID(server:server,username:username,domain:domain)] =
            ["server":server.absoluteString,"username":username,"domain":domain,"share":share,"updated":String(Date().timeIntervalSince1970)]
        defaults.set(profiles,forKey:"serverProfiles.v1")
        defaults.set(server.absoluteString, forKey: "server")
        defaults.set(username, forKey: "username")
        defaults.set(domain, forKey: "domain")
        defaults.set(share, forKey: "share")
    }
}
