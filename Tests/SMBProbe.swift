import Foundation
import AMSMB2
import CryptoKit

@main struct SMBProbe {
    static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        let client = SMB2Manager(url: url, credential: URLCredential(user: "guest", password: "", persistence: .none))!
        client.timeout = 10
        let shares = try await client.listShares()
        precondition(shares.contains(where: { $0.name == "TESTMEDIA" }))
        try await client.connectShare(name: "TESTMEDIA")
        let root = try await client.contentsOfDirectory(atPath: "")
        precondition(root.contains(where: { $0[.nameKey] as? String == "Nested" && $0[.fileResourceTypeKey] as? URLFileResourceType == .directory }))
        let files = try await client.contentsOfDirectory(atPath: "Nested")
        let name = "VP9 sample ✓.webm"
        precondition(files.contains(where: { $0[.nameKey] as? String == name && ($0[.fileSizeKey] as? NSNumber)?.int64Value ?? 0 > 0 }))
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try await client.downloadItem(atPath: "Nested/\(name)", to: output, progress: { _, _ in true })
        let expected = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        let actual = SHA256.hash(data: try Data(contentsOf: output))
        precondition(actual == expected)
        print("PASS: SMB2 share enumeration, nested directory, Unicode/spaces, size and full download SHA-256")
        do { try await client.disconnectShare(gracefully: true) }
        catch { print("Test server rejected clean SMB logoff: \(error.localizedDescription)") }
    }
}
