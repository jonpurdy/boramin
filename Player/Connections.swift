import SwiftUI

/// Saved connections use platform-standard list rows; opening connects only on demand.
struct ConnectionsList: View {
    @ObservedObject private var store = ConnectionPreferences.shared
    var onOpen: ((SMBConnection) -> Void)? = nil
    @State private var editor: ConnectionDraft?
    @State private var connectionToDelete: SMBConnection?
    #if os(macOS)
    @State private var selection = Set<String>()
    #endif
    var body: some View {
        connectionList
        #if os(tvOS)
        .font(.system(size: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .regular))
        .listStyle(.plain)
        .background(Color.black.ignoresSafeArea())
        #elseif os(iOS)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        #endif
        .navigationTitle("Connections")
        .sheet(item: $editor) { draft in ConnectionEditor(draft: draft) }
        .alert("Delete Connection?", isPresented: Binding(get: { connectionToDelete != nil }, set: { if !$0 { connectionToDelete = nil } }), presenting: connectionToDelete) { connection in
            Button("Delete", role: .destructive) {
                store.delete(id: connection.id)
                #if os(macOS)
                selection.remove(connection.id)
                #endif
                connectionToDelete = nil
            }
            Button("Cancel", role: .cancel) { connectionToDelete = nil }
        } message: { connection in
            Text("Delete \(connection.title)? This removes the saved connection from your synced devices when iCloud sync is enabled. Server files, favorites and playback history are kept.")
        }
        .onAppear { store.reload() }
    }
    @ViewBuilder private var connectionList: some View {
        #if os(macOS)
        List(selection: $selection) {
            ForEach(store.connections) { connection in
                row(connection).tag(connection.id)
            }
            Button("Add connection…", systemImage: "plus") { editor = ConnectionDraft() }
                .buttonStyle(.borderless)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let connection = store.connections.first(where: { ids.contains($0.id) }) {
                if onOpen != nil { Button("Open") { open(connection) } }
                Button("Edit Connection…") { editor = ConnectionDraft(connection: connection) }
                Button("Delete Connection…", role: .destructive) { connectionToDelete = connection }
            }
        } primaryAction: { ids in
            if let connection = store.connections.first(where: { ids.contains($0.id) }) { open(connection) }
        }
        #else
        List {
            ForEach(store.connections) { connection in
                Button { open(connection) } label: { row(connection) }
                    #if os(iOS)
                    .buttonStyle(.plain)
                    #endif
                    .contextMenu {
                        Button("Edit Connection…", systemImage: "pencil") { editor = ConnectionDraft(connection: connection) }
                        Button("Delete Connection…", systemImage: "trash", role: .destructive) { connectionToDelete = connection }
                    }
            }
            Button("Add connection…", systemImage: "plus") { editor = ConnectionDraft() }
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
        }
        #endif
    }
    private func row(_ connection: SMBConnection) -> some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.title).foregroundStyle(.primary)
                Text(connection.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func open(_ connection: SMBConnection) {
        if let onOpen { onOpen(connection) }
        else { editor = ConnectionDraft(connection: connection) }
    }
}

private struct ConnectionDraft: Identifiable {
    var id = UUID().uuidString
    var name = ""
    var server = ""
    var username = ""
    var password = ""
    var domain = ""
    var share = ""
    var existing = false
    @MainActor init(connection: SMBConnection? = nil) {
        if let connection {
            id = connection.id; name = connection.name; server = connection.server
            username = connection.username; domain = connection.domain; share = connection.share
            password = ConnectionPreferences.shared.password(address: server, username: username, domain: domain) ?? ""
            existing = true
        }
    }
}

private struct ConnectionEditor: View {
    @State var draft: ConnectionDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            editorFields
            #if os(iOS) || os(tvOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .navigationTitle(draft.existing ? "Edit Connection" : "Add Connection")
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(draft.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #endif
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        #endif
    }
    @ViewBuilder private var editorFields: some View {
        #if os(tvOS)
        // Native tvOS text fields already provide their own focusable chrome.
        // Form rows add a second container around each field.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { fields }
                .padding(40)
        }
        #else
        Form { fields }
        #endif
    }
    @ViewBuilder private var fields: some View {
        TextField("Name (optional)", text: $draft.name)
        TextField("Server", text: $draft.server)
        TextField("Username (empty for guest)", text: $draft.username)
        SecureField("Password", text: $draft.password)
        TextField("Domain (optional)", text: $draft.domain)
        TextField("Share (optional)", text: $draft.share)
        Text("Leave Share empty to browse the server’s shares. Passwords are saved in Keychain. Saving does not require the server to be online. Changes apply the next time you open the connection.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        #if os(tvOS)
        Button("Save", action: save).disabled(draft.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel") { dismiss() }
        #endif
    }
    private func save() {
        guard let url = ConnectionPreferences.serverURL(draft.server) else {
            error = "Enter a server name or IP address, such as smb://nas.local. Enter the share separately."
            return
        }
        do {
            try ConnectionPreferences.shared.save(server: url, username: draft.username, domain: draft.domain,
                share: draft.share, password: draft.password, id: draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), select: false)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

#if os(macOS)
struct ConnectionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ConnectionsList()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(width: 540, height: 450)
    }
}
#endif

struct ConnectionEditButton: View {
    let connection: SMBConnection
    @State private var editor: ConnectionDraft?
    var body: some View {
        Button("Edit Connection…") { editor = ConnectionDraft(connection: connection) }
            .sheet(item: $editor) { draft in ConnectionEditor(draft: draft) }
    }
}

extension FavoriteLocation {
    @MainActor var currentLocation: String {
        let address = ConnectionPreferences.shared.resolve(id: connectionID, server: server, share: share)?.server ?? server
        return "\(address)/\(share)\(path.isEmpty ? "" : "/\(path)")"
    }
}

extension PlaybackFile {
    @MainActor var currentFolderLocation: String {
        let address = ConnectionPreferences.shared.resolve(id: connectionID, server: server, username: username, domain: domain, share: share)?.server ?? server
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "\(address)/\(share)" : "\(address)/\(share)/\(folder)"
    }
}

extension PlaybackFile {
    @MainActor func listPlaybackDetails(duration: Double) -> String {
        let key = MediaMetadataCache.key(server: URL(string: server)!, connectionID: connectionID, share: share, path: path, size: size)
        // Watching probes only visible uncached rows, then reuses this device-local metadata.
        let route = MediaMetadataCache.shared.value(for: key)?.route ?? PlaybackRoute.expected(fileExtension: (name as NSString).pathExtension, vp9: nil)
        return BrowserEntry(name: name, path: path, directory: false, size: size, duration: duration, playbackRoute: route).playbackDetails
    }
}

struct WatchingPlaybackDetails: View {
    let file: PlaybackFile
    let duration: Double
    @ObservedObject var browser: Browser
    @ObservedObject private var cache = MediaMetadataCache.shared
    var body: some View {
        Text(file.listPlaybackDetails(duration: duration))
            .task(id: file.key + (file.connectionID ?? "") + (browser.busy || browser.playing != nil ? "suspended" : "visible")) {
                await browser.loadWatchingMetadata(file)
            }
    }
}
