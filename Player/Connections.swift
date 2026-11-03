import SwiftUI

struct PlaybackMediaIcon: View {
    let symbol: String
    var progress: PlaybackProgress? = nil
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = 24

    var body: some View {
        Group {
            if let progress { PlaybackProgressPie(progress: progress) }
            else { Image(systemName: symbol) }
        }
        #if os(tvOS)
        .frame(width: 48)
        #else
        .frame(width: columnWidth)
        #endif
    }
}

/// Saved playback position, starting at twelve o'clock and filling clockwise.
struct PlaybackProgressPie: View {
    let progress: PlaybackProgress
    @Environment(\.isFocused) private var isFocused
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 18

    private var fraction: Double {
        guard progress.seconds.isFinite, progress.duration.isFinite, progress.duration > 0 else { return 0 }
        return min(1, max(0, progress.seconds / progress.duration))
    }

    private var indicatorColor: Color {
        #if os(tvOS)
        isFocused ? .black : .white
        #else
        .primary
        #endif
    }

    var body: some View {
        ZStack {
            Circle().strokeBorder(indicatorColor, lineWidth: 2)
            PlaybackPieSector(fraction: fraction).fill(indicatorColor).padding(2)
        }
        #if os(tvOS)
        .frame(width: 28, height: 28)
        #else
        .frame(width: diameter, height: diameter)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent watched")
    }
}

private struct PlaybackPieSector: Shape {
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        if fraction >= 1 { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Saved connections use platform-standard list rows; opening connects only on demand.
struct ConnectionsList: View {
    @ObservedObject private var store = ConnectionPreferences.shared
    var onOpen: ((SavedConnection) -> Void)? = nil
    @State private var editor: ConnectionDraft?
    @State private var connectionToDelete: SavedConnection?
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
            #if os(tvOS)
            Button { editor = ConnectionDraft() } label: {
                connectionRow(symbol: "plus") { Text("Add connection…") }
            }
            #else
            Button("Add connection…", systemImage: "plus") { editor = ConnectionDraft() }
                .buttonStyle(.plain)
            #endif
        }
        #endif
    }
    private func row(_ connection: SavedConnection) -> some View {
        connectionRow(symbol: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.title).foregroundStyle(.primary)
                Text(connection.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func connectionRow<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: connectionRowSpacing) {
            Image(systemName: symbol)
                #if os(tvOS)
                .frame(width: 64)
                #endif
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private var connectionRowSpacing: CGFloat? {
        #if os(tvOS)
        24
        #else
        nil
        #endif
    }
    private func open(_ connection: SavedConnection) {
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
    var kind: ConnectionKind = .smb
    var existing = false
    @MainActor init(connection: SavedConnection? = nil) {
        if let connection {
            kind = connection.kind
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
        if !draft.existing {
            Picker("Connection Type", selection: $draft.kind) {
                ForEach(ConnectionKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
        }
        TextField("Name (optional)", text: $draft.name)
        TextField(draft.kind == .smb ? "Server" : "Base URL (https://server/media/)", text: $draft.server)
        TextField(draft.kind == .smb ? "Username (empty for guest)" : "Username (optional)", text: $draft.username)
        SecureField(draft.kind == .smb ? "Password" : "Password (optional)", text: $draft.password)
        if draft.kind == .smb {
            TextField("Domain (optional)", text: $draft.domain)
            TextField("Share (optional)", text: $draft.share)
        }
        Text(draft.kind == .http ? "Browse a Caddy JSON file listing. HTTP connections are read-only. Passwords are saved in Keychain; use HTTPS to protect credentials and media in transit." : "Leave Share empty to browse the server’s shares. Passwords are saved in Keychain. Saving does not require the server to be online. Changes apply the next time you open the connection.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        #if os(tvOS)
        Button("Save", action: save).disabled(draft.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel") { dismiss() }
        #endif
    }
    private func save() {
        guard let url = ConnectionPreferences.connectionURL(draft.server), (url.scheme == "smb") == (draft.kind == .smb) else {
            error = draft.kind == .smb ? "Enter a server name or IP address, such as smb://nas.local. Enter the share separately." : "Enter an HTTP or HTTPS base URL without credentials, a query, or a fragment."
            return
        }
        do {
            try ConnectionPreferences.shared.save(server: url, username: draft.username, domain: draft.domain,
                share: draft.share, password: draft.password, id: draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), select: false, kind: draft.kind)
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
    let connection: SavedConnection
    @State private var editor: ConnectionDraft?
    var body: some View {
        VStack(spacing: 0) {
            Button("Edit Connection…") {
                guard editor == nil else { return }
                editor = ConnectionDraft(connection: connection)
            }
        }
        // Present outside the action button and reset styles inherited from
        // ContentUnavailableView.actions before hosting editable form controls.
        .sheet(item: $editor) { draft in
            ConnectionEditor(draft: draft)
                #if os(iOS)
                .buttonStyle(.automatic)
                .textFieldStyle(.automatic)
                #endif
        }
    }
}

extension FavoriteLocation {
    @MainActor var currentLocation: String {
        let address = ConnectionPreferences.shared.resolve(id: connectionID, server: server, share: share)?.server ?? server
        if let root = URL(string: address), root.scheme != "smb" {
            return path.isEmpty ? address : root.appendingPathComponent(path, isDirectory: true).absoluteString
        }
        return "\(address)/\(share)\(path.isEmpty ? "" : "/\(path)")"
    }
}

extension PlaybackFile {
    @MainActor var currentFolderLocation: String {
        let address = ConnectionPreferences.shared.resolve(id: connectionID, server: server, username: username, domain: domain, share: share)?.server ?? server
        let folder = (path as NSString).deletingLastPathComponent
        if let root = URL(string: address), root.scheme != "smb" {
            return folder.isEmpty ? address : root.appendingPathComponent(folder, isDirectory: true).absoluteString
        }
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
