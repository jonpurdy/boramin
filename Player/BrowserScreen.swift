import SwiftUI

#if os(tvOS) || os(iOS)
struct BrowserScreen: View {
    private var listPrimaryFont: Font? {
        #if os(tvOS)
        .headline.weight(.regular)
        #else
        nil
        #endif
    }
    private var listSecondaryFont: Font {
        #if os(tvOS)
        .body
        #else
        .caption
        #endif
    }
    private var fileDetailsFont: Font? {
        #if os(tvOS)
        .body
        #else
        nil
        #endif
    }
    private enum Destination: Hashable { case files, favorites, favoriteFiles(FavoriteLocation), watching, settings, connections }
    @StateObject private var filesBrowser = Browser()
    @StateObject private var favoriteBrowser = Browser()
    @StateObject private var watchingBrowser = Browser()
    @State private var watching = PlaybackPositions.shared.watching()
    @State private var watchingFileToDelete: PlaybackFile?
    @StateObject private var favorites = Favorites()
    @StateObject private var cloud = ICloudSync.shared
    @State private var navigation: [Destination] = []
    @State private var fileToDelete: BrowserEntry?
    @AppStorage("displayAllFiles") private var displayAllFiles = false
    @AppStorage("showDebugInfo") private var showDebugInfo = false
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var listingFocus
    @FocusState private var focusedHome: Destination?
    private var browser: Browser {
        switch navigation.last {
        case .favorites, .favoriteFiles: return favoriteBrowser
        case .watching: return watchingBrowser
        default: return filesBrowser
        }
    }
    private var visibleEntries: [BrowserEntry] {
        browser.entries.filter { displayAllFiles || $0.directory || $0.playable }
    }
    private var firstFocusableEntry: String? {
        visibleEntries.first { $0.directory || $0.playable }?.id
    }
    private var atFavoriteRoot: Bool {
        guard case .favoriteFiles(let favorite) = navigation.last else { return false }
        return browser.share == favorite.share && browser.path == favorite.path
    }
    private var navigationPath: Binding<[Destination]> {
        Binding(get: { navigation }, set: { destinations in
            // Reset before presenting the screen: its foreground task must not
            // reconnect the last server when Connections is opened from Home.
            if navigation.isEmpty, destinations.first == .files {
                filesBrowser.showConnections()
            }
            navigation = destinations
        })
    }
    private var title: String {
        switch navigation.last {
        case .files, .favoriteFiles:
            return browser.share.isEmpty ? "Connections" : "\(browser.share)\(browser.path.isEmpty ? "" : " / \(browser.path)")"
        case .favorites: return "Favorites"
        case .watching: return "Watching"
        case .settings: return "Settings"
        case .connections: return "Connections"
        case nil: return "BoraMin"
        }
    }
    var body: some View {
        NavigationStack(path: navigationPath) {
            home
                .navigationDestination(for: Destination.self) { destination in
                    Group {
                        switch destination {
                        case .files, .favoriteFiles: files
                        case .favorites: favoritesList
                        case .watching: watchingList
                        case .settings: settings
                        case .connections: ConnectionsList()
                        }
                    }
                    .navigationTitle(title)
                }
                #if os(tvOS)
                .navigationTitle("")
                #else
                .navigationTitle("BoraMin")
                #endif
        }
        .background(Color.black.ignoresSafeArea())
        .disabled(browser.busy)
        .task {
            cloud.activate()
            filesBrowser.runSmokeTestIfRequested()
            if CommandLine.arguments.contains("--icloud-sync-check") {
                await cloud.runPreferenceCheckIfRequested()
                await cloud.synchronize()
                UserDefaults.standard.set(cloud.diagnosticSummary(),forKey:"cloudDiagnosticSummary")
                print("BORAMIN_ICLOUD_CHECK \(cloud.status) pending=\(cloud.pendingCount)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:ICloudSync.dataChanged)) { _ in
            favorites.reload()
            watching = PlaybackPositions.shared.watching()
            filesBrowser.reloadSelectedConnection()
            favoriteBrowser.reloadSelectedConnection()
            filesBrowser.refreshProgress()
            favoriteBrowser.refreshProgress()
        }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
                .receive(on: RunLoop.main)) { _ in
                    favorites.reload()
                    watching = PlaybackPositions.shared.watching()
                    filesBrowser.refreshProgress()
                    favoriteBrowser.refreshProgress()
                }
            .overlay {
                if browser.busy {
                    VStack(spacing: 24) {
                        ProgressView()
                        Text(browser.status).multilineTextAlignment(.center)
                        if browser.status.hasPrefix("Opening stream") || browser.status.hasPrefix("Preparing") {
                            Button("Cancel") { browser.cancel() }
                        }
                    }.padding(50).background(Color.black, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .alert("Unable to continue", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("OK") { browser.error = nil }
            } message: { Text(browser.error ?? "") }
            .alert("Delete File?", isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }), presenting: fileToDelete) { entry in
                Button("Delete", role: .destructive) { browser.deleteFile(entry); fileToDelete = nil }
                Button("Cancel", role: .cancel) { fileToDelete = nil }
            } message: { entry in Text("Permanently delete \(entry.name) from the server? This cannot be undone.") }
            .fullScreenCover(item: Binding(get: { browser.playing }, set: { browser.playing = $0 }), onDismiss: { browser.playbackEnded() }) { media in
                NativePlayer(media: media) { message in
                    browser.playing = nil
                    // Present the error after the system player dismisses.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500)); browser.error = message
                    }
                }.ignoresSafeArea()
            }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
    }
    private var home: some View {
        #if os(tvOS)
        HStack(spacing: 70 * homeScale) {
            homeLink("Favorites", symbol: "star", destination: .favorites)
            homeLink("Watching", symbol: "play.rectangle", destination: .watching)
            homeLink("Connections", symbol: "network", destination: .files)
            homeLink("Settings", symbol: "gearshape", destination: .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        #else
        List {
            NavigationLink(value: Destination.favorites) { Label("Favorites", systemImage: "star") }
            NavigationLink(value: Destination.watching) { Label("Watching", systemImage: "play.rectangle") }
            NavigationLink(value: Destination.files) { Label("Connections", systemImage: "network") }
            NavigationLink(value: Destination.settings) { Label("Settings", systemImage: "gearshape") }
        }
        .navigationTitle("BoraMin")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        #endif
    }
    private let homeScale: CGFloat = 0.65
    private func homeLink(_ name: String, symbol: String, destination: Destination) -> some View {
        NavigationLink(value: destination) {
            VStack(spacing: 24 * homeScale) {
                Image(systemName: symbol).font(.system(size: 76 * homeScale))
                Text(name).font(.system(size: UIFont.preferredFont(forTextStyle: .title2).pointSize * homeScale))
            }
            .frame(width: 270 * homeScale * 1.25, height: 240 * homeScale * 1.25)
            .padding(24 * homeScale * 1.25)
            .foregroundStyle(focusedHome == destination ? Color.black : Color.white)
            .background(focusedHome == destination ? Color(white: 0.95) : Color(white: 32.0 / 255),
                        in: RoundedRectangle(cornerRadius: 20 * homeScale))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedHome, equals: destination)
    }
    private var files: some View {
        Group {
            if navigation.last == .files && browser.showingConnections {
                ConnectionsList(onOpen: { filesBrowser.openConnection($0) })
            } else if !browser.connected {
                ContentUnavailableView {
                    Label("Connection unavailable", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text(browser.connectionError ?? "Choose a saved connection or add one in Settings.")
                } actions: {
                    Button("Retry") { Task { await browser.automaticallyConnect() } }
                    Button("Connections") { if navigation.last == .files { browser.showConnections() } else { navigation.append(.connections) } }
                    if let id = browser.connectionID, let saved = ConnectionPreferences.shared.connection(id: id) {
                        ConnectionEditButton(connection: saved)
                    }
                }
            }
            else {
                    List {
                        Group {
                        Button(atFavoriteRoot ? "Back to Favorites" : (browser.path.isEmpty ? "Back" : "Parent folder"), systemImage: "chevron.left") { navigateBack() }
                            .browserDefaultFocus(browser.share.isEmpty ? browser.shares.isEmpty : firstFocusableEntry == nil, in: listingFocus)
                        if browser.share.isEmpty {
                            ForEach(browser.shares, id: \.self) { share in
                                Button(share, systemImage: "externaldrive.connected.to.line.below") { browser.openShare(share) }
                                    .browserDefaultFocus(share == browser.shares.first, in: listingFocus)
                                    .contextMenu { favoriteMenu(browser.favoriteShare(share)) }
                            }
                            if browser.shares.isEmpty { Text("No shares found. Reconnect with a share name.") }
                        } else {
                            ForEach(visibleEntries) { entry in
                                Button {
                                    if entry.directory { browser.openDirectory(entry.path) } else { browser.play(entry) }
                                } label: {
                                    HStack {
                                        Image(systemName: entry.directory ? "folder" : "film")
                                        Text(entry.displayName)
                                        Spacer()
                                        if !entry.directory { Text(entry.playbackDetails).font(fileDetailsFont).foregroundStyle(.secondary) }
                                    }
                                }.disabled(!entry.directory && !entry.playable)
                                    .task(id: browser.metadataTaskID(entry)) { await browser.loadMetadata(entry) }
                                    .browserDefaultFocus(entry.id == firstFocusableEntry, in: listingFocus)
                                    .contextMenu {
                                        if entry.directory { favoriteMenu(browser.favoriteLocation(path: entry.path)) }
                                        else {
                                            Button("Delete File…", systemImage: "trash", role: .destructive) { fileToDelete = entry }
                                        if entry.playable {
                                            Button("Reset playback", systemImage: "arrow.counterclockwise") {
                                                browser.resetPlayback(entry)
                                            }
                                            .disabled(entry.progress == nil)
                                        }
                                        }
                                    }
                            }
                            if visibleEntries.isEmpty {
                                Text(browser.entries.isEmpty ? "This folder is empty." : "No playable media in this folder.")
                            }
                        }
                        }
                    }
                    .listStyle(.plain)
                    .font(listPrimaryFont)
                    #if os(iOS)
                    .scrollContentBackground(.hidden)
                    #endif
                    .buttonBorderShape(.roundedRectangle)
                    .background(Color.black)
                    .browserFocusScope(listingFocus)
                    // A new directory gets a fresh list and its preferred initial focus.
                    .id([browser.host, browser.share, browser.path, displayAllFiles ? "all" : "media"])
                    .browserExitCommand {
                        guard !browser.busy, browser.playing == nil else { return }
                        navigateBack()
                    }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: scenePhase) {
            guard scenePhase == .active, !browser.showingConnections else { return }
            if browser.connected { browser.refreshConnection() }
            else { await browser.automaticallyConnect() }
        }
    }

    private var settings: some View {
        List {
            Section {
                Toggle("Sync via iCloud",isOn:Binding(get:{cloud.enabled},set:{cloud.setEnabled($0)}))
                    .toggleStyle(.switch)
                if cloud.enabled {
                    Text(cloud.statusAndLastSync).font(.body).foregroundStyle(.secondary)
                    Button("Sync now") { Task { await cloud.synchronize() } }.disabled(cloud.syncing)
                }
            } footer: {
                Text("Sync connections, encrypted passwords, favorites, playback positions and preferences across your devices. Turning this off keeps your local data.").font(.body).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Display all files", isOn: $displayAllFiles)
                    .toggleStyle(.switch)
            } footer: {
                Text("Show other files alongside folders and supported videos. Hidden files stay hidden.").font(.body).foregroundStyle(.secondary)
            }
            Section {
                SubtitleSizeSetting()
            } footer: {
                Text("For external and ASS/SSA subtitles. Native captions use system settings. Saved on this device.").font(.body).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Debug Info", isOn: $showDebugInfo)
                    .toggleStyle(.switch)
            }
        }
        .font(listPrimaryFont ?? .body)
        .listStyle(.plain)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .background(Color.black.ignoresSafeArea())
    }
    private var favoritesList: some View {
        Group {
            if favorites.locations.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star", description:
                    Text("In Connections, press and hold a folder or share and choose Favorite."))
            } else {
                List(favorites.locations) { favorite in
                    Button {
                        favoriteBrowser.openFavorite(favorite) { navigation.append(.favoriteFiles(favorite)) }
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(favorite.name)
                                Text(favorite.currentLocation).font(listSecondaryFont).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Remove favorite", systemImage: "star.slash", role: .destructive) {
                            favorites.remove(favorite)
                        }
                    }
                }
                .listStyle(.plain)
                .font(listPrimaryFont)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
    private var watchingList: some View {
        Group {
            if watching.isEmpty {
                ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle",
                    description: Text("Videos with a saved playback position appear here."))
            } else {
                List(watching) { video in
                    Button {
                        if let file = video.file { watchingBrowser.openWatching(file) }
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "film")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(video.progress.prefix) \(video.file?.name ?? "Saved video · \(video.id.prefix(6))")")
                                if let file = video.file {
                                    WatchingPlaybackDetails(file: file, duration: video.progress.duration, browser: watchingBrowser).font(listSecondaryFont).foregroundStyle(.secondary)
                                }
                                Text(video.file?.currentFolderLocation ?? "Open this video's folder in Connections to recover its name and location.")
                                    .font(listSecondaryFont).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(video.file == nil)
                    .contextMenu {
                        if let file = video.file {
                            Button("Delete File…", systemImage: "trash", role: .destructive) { watchingFileToDelete = file }
                                .disabled(watchingBrowser.busy)
                        }
                        Button("Reset playback", systemImage: "arrow.counterclockwise") {
                            PlaybackPositions.shared.clear(video.id)
                            watching = PlaybackPositions.shared.watching()
                        }
                    }
                }
                .listStyle(.plain)
                .font(listPrimaryFont)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .alert("Delete File?", isPresented: Binding(get: { watchingFileToDelete != nil }, set: { if !$0 { watchingFileToDelete = nil } }), presenting: watchingFileToDelete) { file in
            Button("Delete", role: .destructive) {
                watchingBrowser.deleteWatchingFile(file) { watching = PlaybackPositions.shared.watching() }
                watchingFileToDelete = nil
            }
            Button("Cancel", role: .cancel) { watchingFileToDelete = nil }
        } message: { file in Text("Permanently delete \(file.name) from the server? This cannot be undone.") }
        .onAppear { watching = PlaybackPositions.shared.watching() }
        .task {
            for location in favorites.locations {
                guard !Task.isCancelled, watching.contains(where: { $0.file == nil }) else { return }
                await watchingBrowser.recoverWatchingMetadata(at: location)
                watching = PlaybackPositions.shared.watching()
            }
        }
    }
    @ViewBuilder private func favoriteMenu(_ location: FavoriteLocation?) -> some View {
        if let location {
            Button("Favorite", systemImage: "star") { favorites.add(location) }
                .disabled(favorites.contains(location))
        }
    }
    private func navigateBack() {
        guard !browser.busy, browser.playing == nil else { return }
        if atFavoriteRoot {
            navigation.removeLast()
        } else if navigation.last == .files && !browser.showingConnections && browser.path.isEmpty && browser.share.isEmpty {
            browser.showConnections()
        } else if navigation.last == .files && !browser.showingConnections && browser.path.isEmpty && !browser.directShare.isEmpty {
            browser.showConnections()
        } else if !browser.path.isEmpty || (!browser.share.isEmpty && browser.directShare.isEmpty) {
            browser.back()
        } else if !navigation.isEmpty {
            navigation.removeLast()
        }
    }
}

private extension View {
    @ViewBuilder func browserDefaultFocus(_ preferred: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        prefersDefaultFocus(preferred, in: namespace)
        #else
        self
        #endif
    }
    @ViewBuilder func browserFocusScope(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }
    @ViewBuilder func browserExitCommand(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

#endif
