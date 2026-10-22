import Foundation
import CloudKit
import CryptoKit
import Combine
import Security

/// A disposable, synthetic-data probe. Does not read the player's preferences or secrets.
@MainActor final class CloudSyncProbe: ObservableObject, CKSyncEngineDelegate {
    struct Value: Codable, Identifiable {
        var id: String
        var kind: String
        var fields: [String: String]
        var state: String
        var updatedAt: Date
        var operationID: String
    }
    struct Item: Codable {
        var value: Value
        var systemFields: Data?
    }
    struct DiskState: Codable {
        var items: [String: Item] = [:]
        var dirty: Set<String> = []
        var deletions: Set<String> = []
        var engine: CKSyncEngine.State.Serialization?
    }
    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @Published private(set) var status = "Connecting to iCloud…"
    @Published private(set) var account = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var values: [Value] = []
    @Published private(set) var pending = 0
    @Published var offline = false
    @Published var busy = false
    private let container = CKContainer(identifier: "iCloud.com.example.BoraMin")
    private let zoneID = CKRecordZone.ID(zoneName: "BoraMinSyncProbe-v1")
    private let secretService = "com.example.BoraMin.SyncTest.Secrets"
    private var engine: CKSyncEngine?
    private var disk = DiskState()
    private var file: URL?
    private var preferencesKey: String?
    private var accountID = ""
    private var lastFailure: Error?
    private var accountChanged = false

    func note(_ message: String) {
        log.append(message)
        if log.count > 60 { log.removeFirst() }
        print("BORAMIN_CLOUD \(message)")
    }
    func start() async throws {
        guard engine == nil else { return }
        let status = try await container.accountStatus()
        guard status == .available else { throw ProbeError(message: "Sign in to iCloud on this device (account status \(status.rawValue)).") }
        let user = try await container.userRecordID()
        accountID = Self.hash(user.recordName)
        account = String(accountID.prefix(10))
        #if os(tvOS)
        // tvOS does not offer the iOS Application Support storage contract.
        // This bounded probe keeps its small snapshot in account-scoped preferences.
        preferencesKey = "cloudProbe.state.\(accountID)"
        if let data = UserDefaults.standard.data(forKey: preferencesKey!) {
            disk = try JSONDecoder().decode(DiskState.self, from: data)
        }
        #else
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoraMinSyncProbe/\(accountID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("state.json")
        if let file, FileManager.default.fileExists(atPath: file.path) {
            disk = try JSONDecoder().decode(DiskState.self, from: Data(contentsOf: file))
        }
        #endif
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: disk.engine, delegate: self)
        // Explicit sync makes queued/offline and process-restart tests reproducible.
        config.automaticallySync = false
        engine = CKSyncEngine(config)
        refresh()
        self.status = "iCloud ready"
        note("ready account=\(account) cached=\(disk.items.count) queued=\(pending)")
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func id(_ run: String, _ name: String) -> String { Self.hash(run + ":" + name) }
    private func recordID(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName: id, zoneID: zoneID) }
    private func persist() throws {
        let data = try JSONEncoder().encode(disk)
        if let preferencesKey {
            guard data.count < 200_000 else { throw ProbeError(message: "Synthetic test store is full. Delete old test runs.") }
            UserDefaults.standard.set(data, forKey: preferencesKey)
        } else if let file { try data.write(to: file, options: .atomic) }
        else { throw ProbeError(message: "iCloud account is not initialized.") }
        refresh()
    }
    private func refresh() {
        values = disk.items.values.map(\.value).sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
        pending = disk.dirty.count + disk.deletions.count
    }
    private func secretQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: secretService,
         kSecAttrAccount as String: accountID + ":" + id]
    }
    private func saveSecret(_ secret: String, id: String) throws {
        var query = secretQuery(id)
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProbeError(message: "Test Keychain write failed (\(status)).") }
    }
    private func secret(_ id: String) throws -> String {
        var query = secretQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw ProbeError(message: "Test Keychain read failed (\(status)).")
        }
        return text
    }
    private func removeSecret(_ id: String) { SecItemDelete(secretQuery(id) as CFDictionary) }

    func edit(run: String, name: String, kind: String, fields: [String: String], state: String = "active", password: String? = nil) throws {
        let key = id(run, name)
        if let password { try saveSecret(password, id: key) }
        var fields = fields
        fields["testRun"] = run
        let value = Value(id: key, kind: kind, fields: fields, state: state, updatedAt: Date(), operationID: UUID().uuidString)
        disk.items[key] = Item(value: value, systemFields: disk.items[key]?.systemFields)
        disk.deletions.remove(key)
        disk.dirty.insert(key)
        try persist()
        status = offline ? "Offline changes saved locally" : "Changes queued"
    }
    private func newer(_ left: Value, than right: Value) -> Bool {
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.operationID > right.operationID
    }
    private func metadata(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private func merge(_ record: CKRecord) throws {
        guard record.recordType == "BoraMinSyncProbe", let data = record.encryptedValues["payload"] as? Data else {
            throw ProbeError(message: "Encrypted test payload is missing.")
        }
        let remote = try JSONDecoder().decode(Value.self, from: data)
        guard remote.id == record.recordID.recordName else { throw ProbeError(message: "Test record identity mismatch.") }
        if let local = disk.items[remote.id], disk.dirty.contains(remote.id), newer(local.value, than: remote) {
            disk.items[remote.id]?.systemFields = metadata(record)
        } else {
            if let password = record.encryptedValues["password"] as? String { try saveSecret(password, id: remote.id) }
            disk.items[remote.id] = Item(value: remote, systemFields: metadata(record))
            disk.dirty.remove(remote.id)
        }
    }
    private func outgoing(_ key: String) throws -> CKRecord? {
        guard let item = disk.items[key] else { return nil }
        let record: CKRecord
        if let data = item.systemFields {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            guard let restored = CKRecord(coder: coder) else { throw ProbeError(message: "Invalid CloudKit record metadata.") }
            coder.finishDecoding()
            record = restored
        } else { record = CKRecord(recordType: "BoraMinSyncProbe", recordID: recordID(key)) }
        record.encryptedValues["payload"] = try JSONEncoder().encode(item.value) as NSData
        if item.value.kind == "server" { record.encryptedValues["password"] = try secret(key) as NSString }
        return record
    }
    private func enqueue(_ syncEngine: CKSyncEngine) {
        syncEngine.state.add(pendingRecordZoneChanges: disk.dirty.map { .saveRecord(recordID($0)) }
                             + disk.deletions.map { .deleteRecord(recordID($0)) })
    }
    func synchronize() async throws {
        guard !offline else { note("offline; \(pending) changes remain queued"); return }
        try await start()
        guard let engine, !accountChanged else { throw ProbeError(message: "Account changed. Relaunch the test app.") }
        lastFailure = nil
        status = "Syncing…"
        // Fetch first: a delayed offline checkpoint must not undo a newer reset.
        try await engine.fetchChanges()
        enqueue(engine)
        for _ in 0..<4 {
            try await engine.sendChanges()
            if let lastFailure { throw lastFailure }
            if disk.dirty.isEmpty && disk.deletions.isEmpty { break }
            enqueue(engine)
        }
        guard disk.dirty.isEmpty && disk.deletions.isEmpty else { throw ProbeError(message: "Some test changes are still pending.") }
        try persist()
        status = "Synced"
        note("synced records=\(disk.items.count) queued=\(pending)")
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let event): disk.engine = event.stateSerialization
            case .accountChange(let event):
                switch event.changeType {
                case .signIn(let user):
                    guard Self.hash(user.recordName) == accountID else { accountChanged = true; break }
                case .signOut, .switchAccounts:
                    accountChanged = true
                    values = []; status = "Account changed. Relaunch the test app."
                    return
                @unknown default: accountChanged = true
                }
            case .fetchedRecordZoneChanges(let event):
                for change in event.modifications where !disk.deletions.contains(change.record.recordID.recordName) { try merge(change.record) }
                for deletion in event.deletions {
                    let key = deletion.recordID.recordName
                    disk.items.removeValue(forKey: key); disk.dirty.remove(key); disk.deletions.remove(key); removeSecret(key)
                }
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords { try merge(record) }
                for key in event.deletedRecordIDs.map(\.recordName) {
                    disk.deletions.remove(key); disk.items.removeValue(forKey: key); removeSecret(key)
                }
                for failure in event.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let remote = failure.error.serverRecord { try merge(remote) }
                    else if failure.error.code == .zoneNotFound { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
                    else { lastFailure = failure.error }
                }
                if let error = event.failedRecordDeletes.values.first { lastFailure = error }
            case .sentDatabaseChanges(let event):
                if let failure = event.failedZoneSaves.first { lastFailure = failure.error }
            default: break
            }
            try persist()
        } catch { lastFailure = error; note("event error: \(error.localizedDescription)") }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !accountChanged else { return nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            guard let self else { return nil }
            do { return try await self.outgoing(recordID.recordName) }
            catch { await self.fail(error); return nil }
        }
    }
    func fail(_ error: Error) {
        lastFailure = error
        status = error.localizedDescription
        note("FAILED \(error.localizedDescription)")
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { fail(error) }
        }
    }
    func seed(_ run: String) throws {
        try edit(run: run, name: "server", kind: "server", fields: ["host":"nas.example.invalid", "port":"445", "username":"synthetic-user", "domain":"", "share":"TestMedia"], password: "synthetic-password-\(run)")
        try edit(run: run, name: "favorite", kind: "favorite", fields: ["path":"Movies/Test Folder"])
        try edit(run: run, name: "position", kind: "position", fields: ["path":"Movies/Test.mkv", "seconds":"12", "duration":"120"], state: "inProgress")
        try edit(run: run, name: "settings", kind: "settings", fields: ["displayAllFiles":"false"])
    }
    func advance(_ run: String, seconds: Int = 90) throws {
        try edit(run: run, name: "position", kind: "position", fields: ["path":"Movies/Test.mkv", "seconds":"\(seconds)", "duration":"120"], state: "inProgress")
    }
    func reset(_ run: String) throws {
        try edit(run: run, name: "position", kind: "position", fields: ["path":"Movies/Test.mkv", "seconds":"0", "duration":"120"], state: "reset")
    }
    func cleanup(_ run: String) throws {
        for key in disk.items.values.filter({ $0.value.fields["testRun"] == run }).map({ $0.value.id }) {
            disk.dirty.remove(key); disk.deletions.insert(key)
        }
        try persist()
    }
    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError(message: message) }
    }
    func exercise(run: String, action: String) async throws {
        try await start()
        switch action {
        case "seed":
            try seed(run); try await synchronize()
        case "tv-roundtrip":
            try await synchronize()
            try require(disk.items[id(run,"server")]?.value.fields["host"] == "nas.example.invalid", "Server did not sync.")
            try require(secret(id(run,"server")) == "synthetic-password-\(run)", "Encrypted password did not decrypt into local Keychain.")
            try require(disk.items[id(run,"favorite")] != nil && disk.items[id(run,"settings")] != nil, "Favorites/settings did not sync.")
            try advance(run)
            try edit(run: run, name: "tv-favorite", kind: "favorite", fields: ["path":"Movies/Added on TV"])
            try await synchronize()
            offline = true
            try advance(run, seconds: 20)
            try edit(run: run, name: "offline-favorite", kind: "favorite", fields: ["path":"Movies/Offline TV Edit"])
            note("offline checkpoint and favorite persisted; queued=\(pending)")
        case "phone-reset":
            try await synchronize()
            try require(disk.items[id(run,"position")]?.value.fields["seconds"] == "90", "TV position did not sync back.")
            try require(disk.items[id(run,"tv-favorite")] != nil, "TV favorite did not sync back.")
            try reset(run); try await synchronize()
        case "tv-restart":
            try require(disk.items[id(run,"position")]?.value.fields["seconds"] == "20" && pending >= 2, "Offline edits did not survive process restart.")
            offline = false; try await synchronize()
            try require(disk.items[id(run,"position")]?.value.state == "reset", "Old offline checkpoint resurrected a reset.")
            try require(disk.items[id(run,"offline-favorite")] != nil, "Independent offline favorite was lost.")
        case "phone-verify":
            try await synchronize()
            try require(disk.items[id(run,"position")]?.value.state == "reset", "Reset did not survive sync.")
            try require(disk.items[id(run,"offline-favorite")] != nil, "Offline TV favorite did not sync to phone.")
            try require(secret(id(run,"server")) == "synthetic-password-\(run)", "Password did not survive phone restart.")
        case "cleanup": try cleanup(run); try await synchronize()
        case "verify-cleanup":
            try await synchronize()
            try require(!disk.items.values.contains { $0.value.fields["testRun"] == run }, "Deleted test records remain.")
        default: throw ProbeError(message: "Unknown test action.")
        }
        note("PASS action=\(action) run=\(run)")
    }
}
