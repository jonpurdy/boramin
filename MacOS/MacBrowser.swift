import SwiftUI
import AppKit

private enum LibrarySection: String, CaseIterable, Identifiable {
    case files = "Files", favorites = "Favorites", watching = "Watching"
    var id: Self { self }
    var symbol: String { switch self { case .files: "folder"; case .favorites: "star"; case .watching: "play.rectangle" } }
}

struct MacLibraryView: View {
    @ObservedObject var library: MacLibrary
    @StateObject private var favorites = Favorites()
    @State private var section: LibrarySection? = .files
    @State private var favoriteOpen = false
    @State private var favoriteRoot = ""
    @State private var favoriteSelection = Set<String>()
    @State private var watchingSelection = Set<String>()
    @State private var watching: [WatchingVideo] = []
    @State private var search = ""
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationSplitView {
            List(LibrarySection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("BoraMin")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack { SettingsLink { Label("Settings", systemImage: "gearshape") }; Spacer() }
                    .buttonStyle(.borderless).padding(12)
            }
        } detail: {
            Group {
                switch section ?? .files {
                case .files:
                    MacFilesView(browser: library.files, favorites: favorites, search: search, rootBack: nil, showConnection: { library.showConnection = true })
                case .favorites:
                    if favoriteOpen {
                        MacFilesView(browser: library.favoritesBrowser, favorites: favorites, search: search,
                            rootPath: favoriteRoot, rootBack: { favoriteOpen = false },
                            showConnection: { library.showConnection = true })
                    } else { favoriteTable }
                case .watching: watchingTable
                }
            }
            .searchable(text: $search, prompt: "Filter \((section ?? .files).rawValue)")

        }
        .sheet(isPresented: $library.showConnection) { MacConnectionView(browser: library.files) }
        .background {
            PlaybackPresenter(browser: library.files)
            PlaybackPresenter(browser: library.favoritesBrowser)
            PlaybackPresenter(browser: library.watchingBrowser)
        }
        .task { refreshSavedLists() }
        .onChange(of: section) { _, _ in search = ""; refreshSavedLists() }
        .onChange(of: phase) { _, value in
            if value == .active { ICloudSync.shared.schedule(); refreshSavedLists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ICloudSync.dataChanged)) { _ in
            refreshSavedLists()
            Task { await library.files.automaticallyConnect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BoraMinPlaybackSync"))) { _ in refreshSavedLists() }
    }
    private var favoriteTable: some View {
        Table(favorites.locations.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, selection: $favoriteSelection) {
            TableColumn("Name") { item in Label(item.name, systemImage: "folder") }
            TableColumn("Location", value: \.location)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = favorites.locations.first(where: { ids.contains($0.id) }) {
                Button("Open") { openFavorite(item) }
                Button("Remove Favorite", role: .destructive) { favorites.remove(item) }
            }
        } primaryAction: { ids in
            if let item = favorites.locations.first(where: { ids.contains($0.id) }) { openFavorite(item) }
        }
        .overlay { if favorites.locations.isEmpty { ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Control-click a folder or share in Files and choose Favorite.")) } }
        .navigationTitle("Favorites")
    }
    private var watchingTable: some View {
        Table(watching.filter { search.isEmpty || ($0.file?.name ?? "").localizedCaseInsensitiveContains(search) }, selection: $watchingSelection) {
            TableColumn("Name") { item in Text(item.file.map { "\(item.progress.prefix) \($0.name)" } ?? "\(item.progress.prefix) Unavailable video") }
            TableColumn("Length / Size") { item in
                if let file = item.file { Text(BrowserEntry(name: file.name, path: file.path, directory: false, size: file.size, duration: item.progress.duration).sizeAndDuration).foregroundStyle(.secondary) }
            }.width(190)
            TableColumn("Last Saved") { item in Text(Date(timeIntervalSince1970: item.lastSaved), style: .relative) }.width(130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = watching.first(where: { ids.contains($0.id) }) {
                if let file = item.file { Button("Resume") { library.watchingBrowser.openWatching(file) } }
                Button("Reset Playback") { PlaybackPositions.shared.clear(item.id); refreshSavedLists() }
            }
        } primaryAction: { ids in
            if let file = watching.first(where: { ids.contains($0.id) })?.file { library.watchingBrowser.openWatching(file) }
        }
        .overlay { if watching.isEmpty { ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text("Videos you leave unfinished appear here, most recently saved first.")) } }
        .navigationTitle("Watching")
    }
    private func openFavorite(_ item: FavoriteLocation) {
        let browser = library.favoritesBrowser
        browser.useCredentials(from: library.files)
        browser.openFavorite(item) { favoriteRoot = item.path; favoriteOpen = true }
    }
    private func refreshSavedLists() { favorites.reload(); watching = PlaybackPositions.shared.watching(); library.files.refreshProgress(); library.favoritesBrowser.refreshProgress() }
}

private struct MacFileRow: Identifiable {
    let id: String
    let name: String
    let displayName: String
    let directory: Bool
    let size: Int64
    let entry: BrowserEntry?
    var kind: String {
        if directory { return "Folder" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext + (entry?.playable == true ? " video" : " file")
    }
}

private struct MacFilesView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var favorites: Favorites
    let search: String
    var rootPath: String? = nil
    let rootBack: (() -> Void)?
    let showConnection: () -> Void
    @AppStorage("displayAllFiles") private var allFiles = false
    @State private var selection = Set<String>()
    @State private var fileToDelete: BrowserEntry?
    @State private var sortOrder = [KeyPathComparator(\MacFileRow.name, comparator: .localizedStandard)]
    @Environment(\.scenePhase) private var phase
    private var rows: [MacFileRow] {
        let rows = browser.share.isEmpty ? browser.shares.map { MacFileRow(id: $0, name: $0, displayName: $0, directory: true, size: 0, entry: nil) } :
            browser.entries.filter { allFiles || $0.directory || $0.playable }.map { MacFileRow(id: $0.id, name: $0.name, displayName: $0.displayName, directory: $0.directory, size: $0.size, entry: $0) }
        return rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted(using: sortOrder)
    }
    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in Label(row.displayName, systemImage: row.directory ? "folder" : "film").lineLimit(1) }.width(min: 250, ideal: 440)
            TableColumn("Kind") { row in Text(row.entry == nil ? "SMB Share" : row.kind).foregroundStyle(.secondary) }.width(100)
            TableColumn("Size") { row in Text(row.directory ? "—" : (row.entry?.sizeAndDuration ?? ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))).foregroundStyle(.secondary).task(id: row.id) { if let entry = row.entry { await browser.loadDuration(entry) } } }.width(190)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button(row.directory ? "Open" : "Play") { open(row) }.disabled(browser.busy || (!row.directory && row.entry?.playable != true))
                if row.directory, let favorite = location(row) {
                    if favorites.contains(favorite) { Button("Remove Favorite") { favorites.remove(favorite) } }
                    else { Button("Favorite") { favorites.add(favorite) } }
                }
                if let entry = row.entry, !entry.directory {
                    Button("Delete File…", role: .destructive) { fileToDelete = entry }
                }
                if let entry = row.entry, entry.progress != nil { Button("Reset Playback") { browser.resetPlayback(entry) } }
            }
        } primaryAction: { ids in if let row = rows.first(where: { ids.contains($0.id) }), !browser.busy { open(row) } }
        .alert("Delete File?", isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }), presenting: fileToDelete) { entry in
            Button("Delete", role: .destructive) { browser.deleteFile(entry); fileToDelete = nil; selection.remove(entry.id) }
            Button("Cancel", role: .cancel) { fileToDelete = nil }
        } message: { entry in Text("Permanently delete \(entry.name) from the server? This cannot be undone.") }
        .navigationTitle(browser.share.isEmpty ? "Files" : (browser.path.isEmpty ? browser.share : (browser.path as NSString).lastPathComponent))
        .navigationSubtitle(browser.share.isEmpty ? "SMB Shares" : "\(browser.share)/\(browser.path)")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { if let rootBack, browser.path == rootPath { rootBack() } else { browser.back() } } label: { Label("Enclosing Folder", systemImage: "chevron.left") }
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(browser.busy || (rootBack == nil && browser.share.isEmpty))
                Button { browser.refreshConnection() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r").disabled(browser.busy || !browser.connected)
            }
            ToolbarItem { Button(action: showConnection) { Label("Connection Setup", systemImage: "network") }.help("Connection Setup") }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if browser.busy { ProgressView().controlSize(.small); Text(browser.status); Button("Cancel") { browser.cancel() }.buttonStyle(.link) }
                else { Text("\(rows.count) items"); Spacer(); Text(browser.connected ? "Connected" : "Disconnected").foregroundStyle(.secondary) }
            }.font(.caption).padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
        }
        .overlay {
            if !browser.busy, !browser.connected {
                ContentUnavailableView { Label("Connect to Your Media", systemImage: "externaldrive.connected.to.line.below") }
                    description: { Text(browser.connectionError ?? "Add an SMB server to browse and play your videos.") }
                    actions: { Button("Connection Setup…", action: showConnection); if browser.hasSavedConnection { Button("Retry") { Task { await browser.automaticallyConnect() } } } }
            } else if !browser.busy, rows.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .task {
            await browser.automaticallyConnect(usingSavedConnection: rootBack == nil)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                if NSApp.isActive { await browser.automaticallyConnect(usingSavedConnection: rootBack == nil) }
            }
        }
        .onChange(of: browser.path) { _, _ in selection.removeAll() }
        .onChange(of: browser.share) { _, _ in selection.removeAll() }
        .alert("Unable to Complete Action", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
            Button("OK") { browser.error = nil }
        } message: { Text(browser.error ?? "") }
    }
    private func open(_ row: MacFileRow) {
        if let entry = row.entry {
            if entry.directory { browser.openDirectory(entry.path) }
            else if entry.playable { browser.play(entry) }
        } else { browser.openShare(row.id) }
    }
    private func location(_ row: MacFileRow) -> FavoriteLocation? {
        row.entry == nil ? browser.favoriteShare(row.id) : browser.favoriteLocation(path: row.id)
    }
}

private struct PlaybackPresenter: View {
    @ObservedObject var browser: Browser
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: browser.playing?.id) { _, _ in
                guard let media = browser.playing else { return }
                MacPlaybackWindow.present(media: media) {
                    // Replacing a video may already have installed the next stream
                    // on this Browser. The outgoing window must not stop that stream.
                    if browser.playing?.id == media.id { browser.playbackEnded() }
                    else { browser.refreshProgress() }
                }
            }
            .alert("Unable to Complete Action", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("OK") { browser.error = nil }
            } message: { Text(browser.error ?? "") }
    }
}
