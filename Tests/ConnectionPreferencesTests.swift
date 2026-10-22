import Foundation
import Security

@main struct ConnectionPreferencesTests {
    @MainActor static func main() throws {
        let suite = "BoraMin.ConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: suite] as CFDictionary)
        }
        let store = ConnectionPreferences(defaults: defaults, service: suite)
        precondition(defaults.string(forKey: "server") == nil)
        precondition(store.password(address: "", username: "", domain: "") == nil)
        let server = URL(string: "smb://example.invalid")!
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: " synthetic password \n")
        let reopened = ConnectionPreferences(defaults: UserDefaults(suiteName: suite)!, service: suite)
        precondition(reopened.password(address: "EXAMPLE.invalid:445", username: "test-user", domain: "test") == " synthetic password \n")
        precondition(defaults.string(forKey: "server") == server.absoluteString)
        precondition(defaults.string(forKey: "share") == "Media")
        precondition(defaults.string(forKey: "password") == nil)
        precondition(reopened.password(address: "other.invalid", username: "test-user", domain: "test") == nil)
        precondition(reopened.password(address: "example.invalid:1445", username: "test-user", domain: "test") == nil)
        precondition(reopened.password(address: "example.invalid", username: "other", domain: "test") == nil)
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: "changed")
        precondition(reopened.password(address: "example.invalid", username: "test-user", domain: "test") == "changed")
        try store.save(server: server, username: "", domain: "", share: "", password: "")
        precondition(reopened.password(address: "example.invalid", username: "guest", domain: "") == "")
        let profiles=defaults.dictionary(forKey:"serverProfiles.v1") as? [String:[String:String]]
        precondition(profiles?.count == 2)
        precondition(profiles?.values.allSatisfy { $0["password"] == nil } == true)
        print("PASS: first-run fields empty, connection preferences persist, Keychain passwords survive recreation and update, identities remain separate, and empty guest passwords work")
    }
}
