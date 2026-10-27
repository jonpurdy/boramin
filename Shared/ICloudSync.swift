import OSLog
import Foundation
import CloudKit
import CryptoKit
import Combine

private let cloudLog = Logger(subsystem: "com.example.BoraMin", category: "iCloud")

/// Shared by the tvOS, iOS and macOS apps. Passwords never enter this store.
@MainActor final class ICloudSync: ObservableObject, CKSyncEngineDelegate {
    static let shared = ICloudSync()
    static let dataChanged = Notification.Name("BoraMinCloudDataChanged")
    struct Value: Codable, Equatable {
        var id: String
        var kind: String
        var fields: [String: String]
        var state: String
        var updated: Date
        var operation: String
    }
    struct Item: Codable { var value: Value; var systemFields: Data? }
    struct State: Codable {
        var items: [String: Item] = [:]
        var pending: Set<String> = []
        var engine: CKSyncEngine.State.Serialization?
    }
    struct Snapshot: Equatable {
        var kind: String
        var fields: [String: String]
        var state = "active"
        var updated: Date?
    }
    struct SyncError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "Not synced yet"
    @Published private(set) var syncing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSync: Date?
    private let defaults = UserDefaults.standard
    private let container = CKContainer(identifier: "iCloud.com.example.BoraMin")
    private let zone = CKRecordZone.ID(zoneName: "BoraMinUserData-v1")
    private var engine: CKSyncEngine?
    private var state = State()
    private var observed: [String: Snapshot] = [:]
    private var observer: NSObjectProtocol?
    private var playbackObserver: NSObjectProtocol?
    private var file: URL?
    private var scheduled: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var applying = false
    private var started = false
    private var accountBlocked = false
    private var lastFailure: Error?
    private var storeFailure: Error?
    private var accountID = ""

    init() {
        enabled = defaults.object(forKey: "syncViaICloud") as? Bool ?? true
        lastSync = defaults.object(forKey: "cloudLastSync") as? Date
        accountID = defaults.string(forKey: "cloudOwner.v1") ?? ""
        if !accountID.isEmpty { loadCache() }
        if let data = defaults.data(forKey: "cloudOutbox.v1"),
           let pending = try? JSONDecoder().decode([String: Value].self, from: data) {
            for (key, value) in pending {
                if let existing = state.items[key], newer(existing.value, than: value) { continue }
                state.items[key] = Item(value: value, systemFields: state.items[key]?.systemFields)
                state.pending.insert(key)
            }
        }
        capture(initial: true)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
        playbackObserver=NotificationCenter.default.addObserver(forName:Notification.Name("BoraMinPlaybackSync"),object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.capture(); self?.schedule(delay:0,urgent:true) }
        }
        if !enabled { status = "Off — saved on this device" }
    }
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func id(_ kind: String, _ key: String) -> String { Self.hash(kind + ":" + key) }
    private func recordID(_ key: String) -> CKRecord.ID { CKRecord.ID(recordName: key, zoneID: zone) }
    private func loadCache() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoraMinCloud/\(accountID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("state.json")
            if let file, let data = try? Data(contentsOf: file),
               let cached = try? JSONDecoder().decode(State.self, from: data) {
                state = cached
            }
        } catch { storeFailure = error }
    }
    private func persist() throws {
        // Full CKRecord metadata is a recoverable cache. The small, password-free
        // outbox survives tvOS cache eviction in preferences, alongside local data.
        let pending = Dictionary(uniqueKeysWithValues: state.pending.compactMap { key in
            state.items[key].map { (key, $0.value) }
        })
        let outbox = try JSONEncoder().encode(pending)
        guard outbox.count < 250_000 else { throw SyncError(message: "Too many changes are waiting for iCloud. Sync now to finish saving them.") }
        defaults.set(outbox, forKey: "cloudOutbox.v1")
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(state).write(to: file, options: .atomic)
        }
        pendingCount = pending.count
    }
    private func snapshots() -> [String: Snapshot] {
        var result: [String: Snapshot] = [:]
        var profiles = defaults.dictionary(forKey: "serverProfiles.v1") as? [String: [String: String]] ?? [:]
        let host = defaults.string(forKey: "server") ?? ""
        if let url = Self.serverURL(host) {
            let fields = ["server":url.absoluteString, "username":defaults.string(forKey:"username") ?? "",
                          "domain":defaults.string(forKey:"domain") ?? "", "share":defaults.string(forKey:"share") ?? ""]
            let key = ConnectionPreferences.profileID(server: url, username: fields["username"]!, domain: fields["domain"]!)
            if profiles[key] == nil { profiles[key] = fields }
            result[id("connection", "selected")] = Snapshot(kind: "connection", fields: fields)
        }
        for (key, var fields) in profiles {
            let time = fields.removeValue(forKey: "updated").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            result[id("server", key)] = Snapshot(kind: "server", fields: fields, updated: time)
        }
        if let data = defaults.data(forKey: "favoriteLocations.v1"),
           let favorites = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            for favorite in favorites {
                result[id("favorite", favorite.id)] = Snapshot(kind: "favorite", fields:
                    ["server":favorite.server,"share":favorite.share,"path":favorite.path])
            }
        }
        let bookmarks = defaults.dictionary(forKey:"playbackPositions.v1") as? [String:[String:Double]] ?? [:]
        let resets = defaults.dictionary(forKey:"playbackResets.v1") as? [String:Double] ?? [:]
        let subtitles = defaults.dictionary(forKey: PlaybackPositions.subtitleStorageKey) as? [String: String] ?? [:]
        for (key, value) in bookmarks {
            guard let seconds=value["seconds"], let duration=value["duration"], let updated=value["updated"],
                  seconds.isFinite, duration.isFinite, updated.isFinite, seconds>0, seconds<duration else { continue }
            if (resets[key] ?? 0) >= updated { continue }
            var fields = ["key":key,"seconds":String(seconds),"duration":String(duration)]
            fields["subtitle"] = SavedSubtitleSelection.decode(subtitles[key])?.encoded
            result[id("position",key)] = Snapshot(kind:"position", fields: fields, state:"inProgress", updated:Date(timeIntervalSince1970:updated))
        }
        for (key, file) in PlaybackPositions.shared.allFiles() where result[id("position", key)]?.state == "inProgress" {
            var fields = file.fields
            fields["key"] = key
            result[id("video", key)] = Snapshot(kind: "video", fields: fields)
        }
        for (key, updated) in resets where updated.isFinite && updated >= (bookmarks[key]?["updated"] ?? 0) {
            result[id("position",key)] = Snapshot(kind:"position",fields:["key":key],state:"reset",updated:Date(timeIntervalSince1970:updated))
        }
        if defaults.persistentDomain(forName:Bundle.main.bundleIdentifier ?? "")?["displayAllFiles"] != nil {
            result[id("setting","displayAllFiles")] = Snapshot(kind:"setting",fields:["displayAllFiles":defaults.bool(forKey:"displayAllFiles") ? "true":"false"])
        }
        if defaults.persistentDomain(forName:Bundle.main.bundleIdentifier ?? "")?["showDebugInfo"] != nil {
            result[id("setting", "showDebugInfo")] = Snapshot(kind: "setting", fields: ["showDebugInfo": defaults.bool(forKey: "showDebugInfo") ? "true" : "false"])
        }
        return result
    }
    static func serverURL(_ address: String) -> URL? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var components = URLComponents(string: raw.contains("://") ? raw : "smb://\(raw)"),
              components.scheme == "smb", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.host = host.lowercased()
        if components.port == 445 { components.port = nil }
        components.path = ""
        return components.url
    }
    private func newer(_ left: Value, than right: Value) -> Bool {
        left.updated == right.updated ? left.operation > right.operation : left.updated > right.updated
    }
    private func capture(initial: Bool = false) {
        guard !applying, !accountBlocked else { return }
        let current = snapshots()
        var urgent = false
        var changed = false
        for (key, snapshot) in current where initial || snapshot != observed[key] {
            if let cached = state.items[key]?.value {
                if cached.kind == snapshot.kind && cached.fields == snapshot.fields && cached.state == snapshot.state,
                   snapshot.updated == nil || snapshot.updated! <= cached.updated { continue }
                if initial && (snapshot.updated ?? .distantPast) <= cached.updated { continue }
            }
            let value = Value(id:key,kind:snapshot.kind,fields:snapshot.fields,state:snapshot.state,
                              updated:snapshot.updated ?? (initial ? Date(timeIntervalSince1970:0) : Date()),operation:UUID().uuidString)
            state.items[key] = Item(value:value,systemFields:state.items[key]?.systemFields)
            state.pending.insert(key)
            urgent = urgent || snapshot.kind != "position" || snapshot.state == "reset"
            changed = true
        }
        if !initial {
            for (key, old) in observed where current[key] == nil {
                if old.kind == "position" && old.state == "reset" { continue }
                var fields = old.fields
                if old.kind == "position" { fields.removeValue(forKey: "subtitle") }
                let value = Value(id:key,kind:old.kind,fields:fields,state:old.kind == "position" ? "reset":"deleted",updated:Date(),operation:UUID().uuidString)
                state.items[key] = Item(value:value,systemFields:state.items[key]?.systemFields)
                state.pending.insert(key); urgent=true; changed=true
            }
        }
        observed = current
        if changed {
            do { try persist(); storeFailure=nil }
            catch { storeFailure=error; status=error.localizedDescription }
            if started && enabled { schedule(delay: urgent ? 1 : 45, urgent: urgent) }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled=value; defaults.set(value,forKey:"syncViaICloud")
        if value { schedule(delay:0,urgent:true) }
        else {
            scheduled?.cancel(); scheduled=nil
            status="Off — saved on this device"
            _ = Self.engineTask { [weak self] in await self?.engine?.cancelOperations() }
        }
    }
    func activate() {
        started=true
        if enabled { schedule(delay:0,urgent:true) }
    }
    func schedule(delay: Double = 1, urgent: Bool = false) {
        guard enabled, !accountBlocked else { return }
        if scheduled != nil && !urgent { return }
        scheduled?.cancel()
        scheduled=Self.engineTask { [weak self] in
            do { try await Task.sleep(for:.seconds(delay)) } catch { return }
            guard let self else { return }
            self.scheduled=nil
            await self.synchronize()
        }
    }
    func synchronize() async {
        guard enabled, !accountBlocked else { return }
        if let running { await running.value; return }
        let task=Self.engineTask { await self.runSync() }
        running=task
        await task.value
        running=nil
    }
    // Tasks created while handling a CKSyncEngine event otherwise inherit its
    // task-local delegate context, even after a sleep or a MainActor hop. Apple
    // rejects fetch/send/cancel calls from that context. Start an independent
    // task while keeping all access to our mutable sync state on MainActor.
    nonisolated static func engineTask(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached { @MainActor in await operation() }
    }
    private func prepare() async throws {
        guard engine == nil else { return }
        let status=try await container.accountStatus()
        guard status == .available else { throw SyncError(message:"Sign in to iCloud to sync. Your data stays saved on this device.") }
        let user=try await container.userRecordID()
        let owner=Self.hash(user.recordName)
        if let previous=defaults.string(forKey:"cloudOwner.v1"), previous != owner {
            accountBlocked=true
            throw SyncError(message:"The iCloud account changed. Sync is paused to keep the accounts separate.")
        }
        if accountID.isEmpty {
            accountID=owner; defaults.set(owner,forKey:"cloudOwner.v1")
            loadCache()
        }
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID:zone))
        var config=CKSyncEngine.Configuration(database:container.privateCloudDatabase,stateSerialization:state.engine,delegate:self)
        config.automaticallySync=false
        engine=CKSyncEngine(config)
    }
    private func runSync() async {
        syncing=true
        defer { syncing=false }
        do {
            capture()
            status="Syncing…"
            try await prepare()
            guard let engine, enabled, !accountBlocked else { return }
            lastFailure=nil
            try await engine.fetchChanges()
            guard enabled, !accountBlocked else { return }
            // Cached values also repair local preferences after an interrupted apply.
            applying=true
            defer { applying=false }
            for item in state.items.values { try apply(item.value) }
            observed=snapshots()
            applying=false
            enqueue(engine)
            for _ in 0..<4 {
                guard enabled, !accountBlocked else { return }
                try await engine.sendChanges()
                if let lastFailure { throw lastFailure }
                if state.pending.isEmpty { break }
                enqueue(engine)
            }
            guard state.pending.isEmpty else { throw SyncError(message:"Changes are queued for the next sync.") }
            try persist()
            lastSync=Date(); defaults.set(lastSync,forKey:"cloudLastSync")
            status="Up to date"
            NotificationCenter.default.post(name:Self.dataChanged,object:nil)
            cloudLog.notice("BORAMIN_ICLOUD synced records=\(self.state.items.count) pending=\(self.pendingCount)")
        } catch {
            lastFailure=error
            if enabled { status=error.localizedDescription }
            cloudLog.error("BORAMIN_ICLOUD sync deferred code=\((error as NSError).code)")
            if enabled && !accountBlocked { schedule(delay:60) }
        }
    }
    private func enqueue(_ engine: CKSyncEngine) {
        engine.state.add(pendingRecordZoneChanges:state.pending.map { .saveRecord(recordID($0)) })
    }
    private func metadata(_ record: CKRecord) -> Data {
        let coder=NSKeyedArchiver(requiringSecureCoding:true)
        record.encodeSystemFields(with:coder); coder.finishEncoding()
        return coder.encodedData
    }
    private func outgoing(_ key: String) throws -> CKRecord? {
        guard let item=state.items[key] else { return nil }
        let record: CKRecord
        if let data=item.systemFields {
            let coder=try NSKeyedUnarchiver(forReadingFrom:data); coder.requiresSecureCoding=true
            guard let restored=CKRecord(coder:coder) else { throw SyncError(message:"Could not load iCloud record metadata.") }
            coder.finishDecoding(); record=restored
        } else { record=CKRecord(recordType:"BoraMinUserData",recordID:recordID(key)) }
        record.encryptedValues["payload"]=try JSONEncoder().encode(item.value) as NSData
        if item.value.kind == "server", let address=item.value.fields["server"],
           let password=ConnectionPreferences.shared.password(address:address,username:item.value.fields["username"] ?? "",domain:item.value.fields["domain"] ?? "") {
            record.encryptedValues["password"]=password as NSString
        }
        return record
    }
    private func merge(_ record: CKRecord) throws {
        guard record.recordType == "BoraMinUserData", let data=record.encryptedValues["payload"] as? Data else { throw SyncError(message:"An iCloud record could not be decrypted.") }
        let remote=try JSONDecoder().decode(Value.self,from:data)
        guard remote.id == record.recordID.recordName else { throw SyncError(message:"Invalid iCloud record identity.") }
        if let local=state.items[remote.id], state.pending.contains(remote.id), newer(local.value,than:remote) {
            state.items[remote.id]?.systemFields=metadata(record)
        } else {
            if remote.kind == "server", let password=record.encryptedValues["password"] as? String,
               let address=remote.fields["server"], let server=Self.serverURL(address) {
                try ConnectionPreferences.shared.storePassword(server:server,username:remote.fields["username"] ?? "",domain:remote.fields["domain"] ?? "",password:password)
            }
            state.items[remote.id]=Item(value:remote,systemFields:metadata(record))
            state.pending.remove(remote.id)
            try apply(remote)
        }
    }
    private func apply(_ value: Value) throws {
        let f=value.fields
        switch value.kind {
        case "server":
            guard let address=f["server"], let server=Self.serverURL(address) else { return }
            let key=ConnectionPreferences.profileID(server:server,username:f["username"] ?? "",domain:f["domain"] ?? "")
            var profiles=defaults.dictionary(forKey:"serverProfiles.v1") as? [String:[String:String]] ?? [:]
            if value.state == "deleted" { profiles.removeValue(forKey:key) }
            else { var fields=f; fields["updated"]=String(value.updated.timeIntervalSince1970); profiles[key]=fields }
            defaults.set(profiles,forKey:"serverProfiles.v1")
        case "connection":
            guard value.state != "deleted", let address=f["server"], Self.serverURL(address) != nil else { return }
            for key in ["server","username","domain","share"] { defaults.set(f[key] ?? "",forKey:key) }
        case "favorite":
            guard let address=f["server"], let server=Self.serverURL(address),
                  let share=f["share"], let path=f["path"],
                  let favorite=FavoriteLocation(server:server,share:share,path:path) else { return }
            var favorites=defaults.data(forKey:"favoriteLocations.v1").flatMap { try? JSONDecoder().decode([FavoriteLocation].self,from:$0) } ?? []
            favorites.removeAll { $0.id == favorite.id }
            if value.state != "deleted" { favorites.append(favorite) }
            favorites.sort(by: FavoriteLocation.alphabeticallyPrecedes)
            defaults.set(try JSONEncoder().encode(favorites),forKey:"favoriteLocations.v1")
        case "video":
            guard let key = f["key"] else { return }
            // Inactive metadata is a bounded local cache. Keep it when a cloud
            // bookmark resets so reopening the same video cannot lose its name.
            guard value.state != "deleted" else { return }
            if let file = PlaybackFile(fields: f), file.key == key { PlaybackPositions.shared.remember(file) }
        case "position":
            guard let key=f["key"] else { return }
            var positions=defaults.dictionary(forKey:"playbackPositions.v1") as? [String:[String:Double]] ?? [:]
            var resets=defaults.dictionary(forKey:"playbackResets.v1") as? [String:Double] ?? [:]
            if value.state == "inProgress", let seconds=f["seconds"].flatMap(Double.init), let duration=f["duration"].flatMap(Double.init),
               seconds.isFinite, duration.isFinite, seconds>0, seconds<duration {
                positions[key]=["seconds":seconds,"duration":duration,"updated":value.updated.timeIntervalSince1970]
                resets.removeValue(forKey:key)
            } else {
                positions.removeValue(forKey:key); resets[key]=value.updated.timeIntervalSince1970
            }
            if positions.count>500 {
                for key in positions.keys.sorted(by:{ (positions[$0]?["updated"] ?? 0) > (positions[$1]?["updated"] ?? 0) }).dropFirst(500) { positions.removeValue(forKey:key) }
            }
            if resets.count>500 {
                for key in resets.keys.sorted(by:{ resets[$0]! > resets[$1]! }).dropFirst(500) { resets.removeValue(forKey:key) }
            }
            defaults.set(positions,forKey:"playbackPositions.v1"); defaults.set(resets,forKey:"playbackResets.v1")
            PlaybackPositions(defaults: defaults).applySyncedSubtitle(value.state == "inProgress" ? f["subtitle"] : nil, for: key)
        case "setting":
            if let value=f["displayAllFiles"] { defaults.set(value == "true",forKey:"displayAllFiles") }
            if let value=f["showDebugInfo"] { defaults.set(value == "true",forKey:"showDebugInfo") }
        default: break
        }
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard enabled, !accountBlocked else { return }
        capture()
        applying=true
        defer { applying=false }
        do {
            switch event {
            case .stateUpdate(let event): state.engine=event.stateSerialization
            case .accountChange(let event):
                switch event.changeType {
                case .signIn(let user):
                    if Self.hash(user.recordName) != accountID { accountBlocked=true }
                case .signOut, .switchAccounts: accountBlocked=true
                @unknown default: accountBlocked=true
                }
                if accountBlocked { status="The iCloud account changed. Sync is paused to keep the accounts separate."; return }
            case .fetchedRecordZoneChanges(let event):
                for change in event.modifications { try merge(change.record) }
                // App deletions use tombstones. A hard deletion from iCloud must not
                // be silently resurrected from an old local pending copy.
                for deletion in event.deletions {
                    let key=deletion.recordID.recordName
                    if var item=state.items[key] {
                        item.value.state=item.value.kind == "position" ? "reset":"deleted"
                        if item.value.kind == "position" { item.value.fields.removeValue(forKey: "subtitle") }
                        item.value.updated=Date(); item.value.operation=UUID().uuidString
                        try apply(item.value); state.items[key]=item
                    }
                    state.pending.remove(key)
                }
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords { try merge(record) }
                for failure in event.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let remote=failure.error.serverRecord { try merge(remote) }
                    else if failure.error.code == .zoneNotFound { syncEngine.state.add(pendingDatabaseChanges:[.saveZone(CKRecordZone(zoneID:zone))]) }
                    else { lastFailure=failure.error }
                }
            case .sentDatabaseChanges(let event): if let failure=event.failedZoneSaves.first { lastFailure=failure.error }
            default: break
            }
            observed=snapshots()
            try persist()
            NotificationCenter.default.post(name:Self.dataChanged,object:nil)
        } catch { lastFailure=error }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard enabled, !accountBlocked else { return nil }
        let changes=syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges:changes) { [weak self] recordID in
            guard let self else { return nil }
            do { return try await self.outgoing(recordID.recordName) }
            catch { await self.recordFailure(error); return nil }
        }
    }
    private func recordFailure(_ error: Error) { lastFailure=error }

    /// Device regression hook; never invoked by ordinary launches.
    func runPreferenceCheckIfRequested() async {
        let args=CommandLine.arguments
        guard let index=args.firstIndex(of:"--icloud-preference-check"),args.count>index+1 else { return }
        switch args[index+1] {
        case "disable-and-toggle":
            setEnabled(false)
            defaults.set(!defaults.bool(forKey:"displayAllFiles"),forKey:"displayAllFiles")
            capture()
        case "enable": setEnabled(true); await synchronize()
        case "toggle":
            defaults.set(!defaults.bool(forKey:"displayAllFiles"),forKey:"displayAllFiles")
            capture(); await synchronize()
        default: return
        }
        print("BORAMIN_ICLOUD_PREFERENCE_CHECK action=\(args[index+1]) enabled=\(enabled) pending=\(pendingCount)")
    }

    /// No readable paths or secret values in diagnostic summaries.
    func diagnosticSummary() -> [String: Any] {
        let active=state.items.values.map(\.value).filter { $0.state != "deleted" }
        let encoder=JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data=(try? encoder.encode(active.sorted { $0.id < $1.id })) ?? Data()
        return ["records":active.count,"pending":pendingCount,"status":status,
                "digest":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),
                "servers":active.filter { $0.kind == "server" }.count,
                "credentials":active.filter { value in
                    value.kind == "server" && ConnectionPreferences.shared.password(address:value.fields["server"] ?? "",username:value.fields["username"] ?? "",domain:value.fields["domain"] ?? "") != nil
                }.count,
                "favorites":active.filter { $0.kind == "favorite" }.count,
                "positions":active.filter { $0.kind == "position" && $0.state == "inProgress" }.count]
    }
}
