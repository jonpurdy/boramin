import SwiftUI

#if os(tvOS) || os(iOS)
struct BrowserScreen: View {
    @AppStorage(PlaybackRoute.alwaysUseAetherKey) private var alwaysUseAether = PlaybackRoute.defaultAlwaysUseAether
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
    @State private var speedTestEntry: BrowserEntry?
    @State private var fileToDelete: BrowserEntry?
    @AppStorage("displayAllFiles") private var displayAllFiles = false
    @AppStorage("showDebugInfo") private var showDebugInfo = false
    #if os(tvOS)
    @AppStorage(FolderSortOrder.key) private var folderSortOrder = FolderSortOrder.filenameAscending
    @AppStorage("expandFilenameImmediately") private var expandFilenameImmediately = false
    @AppStorage("oledMode") private var oledMode = false
    @AppStorage(OLEDDimming.key) private var oledDimming = OLEDDimming.defaultValue
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
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
        let entries = browser.entries.filter { displayAllFiles || $0.directory || $0.playable }
        #if os(tvOS)
        return entries.sorted(by: folderSortOrder.precedes)
        #else
        return entries
        #endif
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
            return browser.isShareListing ? "Connections" : (browser.share.isEmpty ? browser.folderTitle : "\(browser.share)\(browser.path.isEmpty ? "" : " / \(browser.path)")")
        case .favorites: return "Favorites"
        case .watching: return "Watching"
        case .settings: return "Settings"
        case .connections: return "Connections"
        case nil: return "BoraMin"
        }
    }
    #if os(tvOS)
    private var tvBrowsingBusy: Bool { filesBrowser.busy || favoriteBrowser.busy || watchingBrowser.busy }
    private var tvPlaying: Bool { filesBrowser.playing != nil || favoriteBrowser.playing != nil || watchingBrowser.playing != nil }
    private var tvMetadataLoading: Bool {
        filesBrowser.loadingMetadata || favoriteBrowser.loadingMetadata || watchingBrowser.loadingMetadata
    }
    #endif
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
        #if os(tvOS)
        .modifier(TopShelfLifecycle(busy: tvBrowsingBusy || tvPlaying,
                                    loading: tvBrowsingBusy || tvMetadataLoading, playing: tvPlaying))
        .onReceive(NotificationCenter.default.publisher(for: .topShelfOpenItem)) { notification in
            guard let url = notification.object as? URL else { return }
            guard url.scheme == "boramin", url.host == "watching",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
            watching = PlaybackPositions.shared.watching()
            navigation = [.watching]
            if let file = watching.first(where: { $0.id == id })?.file {
                watchingBrowser.openWatching(file)
            }
        }
        #endif
        .background(Color.browserBackground.ignoresSafeArea())
        .disabled(browser.busy)
        .task {
            #if os(tvOS)
            TopShelfPublisher.refresh()
            #endif
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
            #if os(tvOS)
            TopShelfPublisher.refresh()
            #endif
            filesBrowser.reloadSelectedConnection()
            favoriteBrowser.reloadSelectedConnection()
            filesBrowser.refreshProgress()
            favoriteBrowser.refreshProgress()
        }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in
                    favorites.reload()
                    watching = PlaybackPositions.shared.watching()
                    #if os(tvOS)
                    TopShelfPublisher.refresh()
                    #endif
                    filesBrowser.refreshProgress()
                    favoriteBrowser.refreshProgress()
                }
            .overlay {
                if browser.busy {
                    VStack(spacing: 24) {
                        #if !os(tvOS)
                        ProgressView()
                        #endif
                        Text(browser.status).multilineTextAlignment(.center)
                        if browser.status.hasPrefix("Opening stream") || browser.status.hasPrefix("Preparing") {
                            Button("Cancel") { browser.cancel() }
                        }
                    }.padding(50).background(Color.browserPanelBackground, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .alert("Unable to continue", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("OK") { browser.error = nil }
            } message: { Text(browser.error ?? "") }
            .sheet(item: $speedTestEntry) { RemoteSpeedTestSheet(browser: browser, entry: $0) }
            .alert("Delete File?", isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }), presenting: fileToDelete) { entry in
                Button("Delete", role: .destructive) { browser.deleteFile(entry); fileToDelete = nil }
                Button("Cancel", role: .cancel) { fileToDelete = nil }
            } message: { entry in Text(entry.playable ? "Permanently delete \(entry.name) and its matching external subtitles from the server? Subtitles shared by another video are kept. This cannot be undone." : "Permanently delete \(entry.name) from the server? This cannot be undone.") }
            .fullScreenCover(item: Binding(get: { browser.playing }, set: { browser.playing = $0 }), onDismiss: { browser.playbackEnded() }) { media in
                NativePlayer(media: media) { message in
                    browser.playing = nil
                    // Present the error after the system player dismisses.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500)); browser.error = message
                    }
                }.ignoresSafeArea()
                    .preferredColorScheme(.dark)
            }
        #if os(tvOS)
        .preferredColorScheme(.dark)
        #endif
        .background(Color.browserBackground.ignoresSafeArea())
        #if os(tvOS)
        .modifier(TVOLEDMode(active: !tvPlaying, location: navigation.count))
        #endif
        .tvBackgroundActivityIndicator()
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
        .background(Color.browserBackground)
        #else
        List {
            NavigationLink(value: Destination.favorites) { Label("Favorites", systemImage: "star") }
            NavigationLink(value: Destination.watching) { Label("Watching", systemImage: "play.rectangle") }
            NavigationLink(value: Destination.files) { Label("Connections", systemImage: "network") }
            NavigationLink(value: Destination.settings) { Label("Settings", systemImage: "gearshape") }
        }
        .navigationTitle("BoraMin")
        .background(Color.browserBackground)
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
                    Button("Retry") { Task { await browser.automaticallyConnect(retry: true) } }
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
                            .browserDefaultFocus(browser.isShareListing ? browser.shares.isEmpty : firstFocusableEntry == nil, in: listingFocus)
                        if browser.isShareListing {
                            ForEach(browser.shares, id: \.self) { share in
                                Button { browser.openShare(share) } label: {
                                    #if os(tvOS)
                                    HStack(spacing: 24) {
                                        Image(systemName: "externaldrive.connected.to.line.below")
                                            .frame(width: 64)
                                        Text(share)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    #else
                                    Label(share, systemImage: "externaldrive.connected.to.line.below")
                                    #endif
                                }
                                    .browserDefaultFocus(share == browser.shares.first, in: listingFocus)
                                    .contextMenu { favoriteMenu(browser.favoriteShare(share)) }
                            }
                            if browser.shares.isEmpty { Text("No shares found. Reconnect with a share name.") }
                        } else {
                            ForEach(visibleEntries) { entry in
                                Button {
                                    if entry.directory { browser.openDirectory(entry.path) }
                                    else if entry.playable { browser.play(entry) }
                                } label: {
                                    mediaRow(symbol: entry.directory ? "folder" : "film", name: entry.name, progress: entry.progress) {
                                        if !entry.directory { Text(entry.playbackDetails(alwaysUseAether: alwaysUseAether)) }
                                    }
                                }
                                    .task(id: browser.metadataTaskID(entry)) { await browser.loadMetadata(entry) }
                                    .browserDefaultFocus(entry.id == firstFocusableEntry, in: listingFocus)
                                    .contextMenu {
                                        if entry.directory { favoriteMenu(browser.favoriteLocation(path: entry.path)) }
                                        else {
                                            if entry.size > 0 {
                                                Button("Speed test…", systemImage: "speedometer") { speedTestEntry = entry }
                                            }
                                            if entry.playable {
                                                Button("Reset playback", systemImage: "arrow.counterclockwise") {
                                                    browser.resetPlayback(entry)
                                                }
                                                .disabled(entry.progress == nil)
                                            }
                                            if browser.canDeleteFiles { Button("Delete File…", systemImage: "trash", role: .destructive) { fileToDelete = entry } }
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
                    .buttonBorderShape(.roundedRectangle)
                    .background(Color.browserBackground)
                    .browserFocusScope(listingFocus)
                    // A new directory gets a fresh list and its preferred initial focus.
                    .id([browser.host, browser.share, browser.path, displayAllFiles ? "all" : "media"])
                    .browserExitCommand {
                        guard !browser.busy, browser.playing == nil else { return }
                        navigateBack()
                    }
            }
        }
        .background(Color.browserBackground.ignoresSafeArea())
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
                #if os(tvOS)
                Picker("List View sort by…", selection: $folderSortOrder) {
                    ForEach(FolderSortOrder.allCases, id: \.self) { order in
                        Text(order == folderSortOrder ? "✓ \(order.rawValue)" : order.rawValue).tag(order)
                    }
                }
                #endif
                Toggle("Use AVPlayer when possible (Experimental)", isOn: Binding(
                    get: { !alwaysUseAether }, set: { alwaysUseAether = !$0 }
                ))
                    .toggleStyle(.switch)
            } footer: {
            }
            #if os(tvOS)
            Section {
                Toggle("OLED Mode", isOn: $oledMode)
                    .toggleStyle(.switch)
                if oledMode {
                    Picker("OLED dimming", selection: $oledDimming) {
                        ForEach(OLEDDimming.allCases, id: \.self) { level in
                            let percentage = level.remainingBrightness.formatted(.percent)
                            Text(level == oledDimming ? "✓ \(percentage)" : percentage).tag(level)
                        }
                    }
                }
            } footer: {
                Text("Dim screens after ten seconds of inactivity. Saved on this device.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Expand filename immediately in list views", isOn: $expandFilenameImmediately)
                    .toggleStyle(.switch)
            } footer: {
                Text("When off, focus a filename for one second to expand it. Saved on this device.")
                    .font(.body).foregroundStyle(.secondary)
            }
            #endif
            Section {
                #if os(tvOS)
                Text("Subtitle Size")
                #endif
                SubtitleSizeSetting()
            }
            Section {
                Toggle("Show Debug Info", isOn: $showDebugInfo)
                    .toggleStyle(.switch)
            }
            Section {
                NavigationLink("Licences") { LicencesView() }
            } footer: {
                SettingsVersionFooter()
            }
        }
        .font(listPrimaryFont ?? .body)
        .listStyle(.plain)
        .background(Color.browserBackground.ignoresSafeArea())
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
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.browserBackground.ignoresSafeArea())
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
                        mediaRow(symbol: "film",
                                 name: video.file?.name ?? "Saved video · \(video.id.prefix(6))",
                                 progress: video.progress,
                                 location: video.file?.currentFolderLocation ?? "Open this video's folder in Connections to recover its name and location.") {
                            if let file = video.file {
                                WatchingPlaybackDetails(file: file, duration: video.progress.duration, browser: watchingBrowser)
                            }
                        }
                    }
                    .disabled(video.file == nil)
                    .contextMenu {
                        Button("Reset playback", systemImage: "arrow.counterclockwise") {
                            PlaybackPositions.shared.clear(video.id)
                            watching = PlaybackPositions.shared.watching()
                        }
                        if let file = video.file {
                            if watchingBrowser.canDelete(file) {
                                Button("Delete File…", systemImage: "trash", role: .destructive) { watchingFileToDelete = file }
                                    .disabled(watchingBrowser.busy)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .font(listPrimaryFont)
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.browserBackground.ignoresSafeArea())
        .alert("Delete File?", isPresented: Binding(get: { watchingFileToDelete != nil }, set: { if !$0 { watchingFileToDelete = nil } }), presenting: watchingFileToDelete) { file in
            Button("Delete", role: .destructive) {
                watchingBrowser.deleteWatchingFile(file) { watching = PlaybackPositions.shared.watching() }
                watchingFileToDelete = nil
            }
            Button("Cancel", role: .cancel) { watchingFileToDelete = nil }
        } message: { file in Text("Permanently delete \(file.name) and its matching external subtitles from the server? Subtitles shared by another video are kept. This cannot be undone.") }
        .onAppear { watching = PlaybackPositions.shared.watching() }
        .task {
            for location in favorites.locations {
                guard !Task.isCancelled, watching.contains(where: { $0.file == nil }) else { return }
                await watchingBrowser.recoverWatchingMetadata(at: location)
                watching = PlaybackPositions.shared.watching()
            }
        }
    }
    private var stacksFileDetails: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass != .compact
        #else
        false
        #endif
    }
    private func mediaRow<Details: View>(symbol: String, name: String, progress: PlaybackProgress? = nil, location: String? = nil,
                                         @ViewBuilder details: () -> Details) -> some View {
        HStack {
            PlaybackMediaIcon(symbol: symbol, progress: progress)
            VStack(alignment: .leading, spacing: 6) {
                MediaFilename(name: name)
                if let location {
                    Text(location).font(listSecondaryFont).foregroundStyle(.secondary)
                }
                if stacksFileDetails {
                    details().font(listSecondaryFont).foregroundStyle(.secondary)
                }
            }
            if stacksFileDetails {
                Spacer(minLength: 0)
            } else {
                Spacer()
                details().font(fileDetailsFont).foregroundStyle(.secondary)
            }
        }
        #if os(tvOS)
        // The entire label changes height when its filename wraps. Suppress
        // inherited focus animation for the surrounding layout as well.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        #endif
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

private struct MediaFilename: View {
    let name: String
    @Environment(\.isFocused) private var isFocused
    #if os(tvOS)
    @AppStorage("expandFilenameImmediately") private var expandImmediately = false
    @State private var delayedExpansion = false
    private struct ExpansionRequest: Hashable {
        let name: String
        let focused: Bool
        let immediate: Bool
    }
    #endif

    var body: some View {
        Text(name)
            #if os(tvOS)
            .lineLimit(isFocused && (expandImmediately || delayedExpansion) ? nil : 1)
            .onChange(of: isFocused) { _, _ in delayedExpansion = false }
            .task(id: ExpansionRequest(name: name, focused: isFocused, immediate: expandImmediately)) {
                delayedExpansion = false
                guard isFocused, !expandImmediately else { return }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                delayedExpansion = true
            }
            #else
            .lineLimit(nil)
            #endif
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            #if os(tvOS)
            // Focus changes the line count; do not interpolate the text layout
            // through the native button's focus animation.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            #endif
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

#if os(tvOS)
/// SwiftUI scene lifecycle owns foreground artwork work, including multi-scene app lifecycles.
private struct TopShelfLifecycle: ViewModifier {
    let busy: Bool
    let loading: Bool
    let playing: Bool
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .onChange(of: phase, initial: true) { _, phase in
                TopShelfPublisher.setForeground(phase == .active)
            }
            .onChange(of: busy, initial: true) { _, busy in
                TopShelfPublisher.setBrowsingBusy(busy)
            }
            .onChange(of: loading, initial: true) { _, loading in
                TVBackgroundActivity.shared.loading = loading
            }
            .onChange(of: playing, initial: true) { _, playing in
                TVBackgroundActivity.shared.playing = playing
            }
    }
}
#endif

#if os(tvOS)
private struct TVActivityOverlay: ViewModifier {
    @ObservedObject private var activity = TVBackgroundActivity.shared
    @ObservedObject private var cloud = ICloudSync.shared
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if !activity.playing && (activity.loading || activity.artwork || cloud.syncing) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(.top, 24)
                    .padding(.trailing, 40)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Background activity")
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder func tvBackgroundActivityIndicator() -> some View {
        #if os(tvOS)
        modifier(TVActivityOverlay())
        #else
        self
        #endif
    }
}

#if os(tvOS)
enum OLEDDimming: Int, CaseIterable {
    case low = 25
    case medium = 50
    case high = 75

    static let key = "oledDimming"
    static let defaultValue = Self.medium
    var remainingBrightness: Double { Double(rawValue) / 100 }
    var opacity: Double { 1 - remainingBrightness }
}

private struct TVOLEDMode: ViewModifier {
    let active: Bool
    let location: Int
    @AppStorage("oledMode") private var enabled = false
    @AppStorage(OLEDDimming.key) private var dimming = OLEDDimming.defaultValue
    @Environment(\.scenePhase) private var phase
    @State private var dimmed = false
    @State private var generation = 0

    private func wake() {
        dimmed = false
        generation += 1
    }
    func body(content: Content) -> some View {
        content
            .overlay {
                Color.black
                    .opacity(enabled && active && dimmed ? dimming.opacity : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: enabled && active && phase == .active ? generation : nil) {
                dimmed = false
                guard enabled, active, phase == .active else { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { dimmed = true }
            }
            .onChange(of: location) { _, _ in wake() }
            .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { _ in wake() }
            .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { _ in wake() }
            .simultaneousGesture(TapGesture().onEnded { wake() })
    }
}
#endif

// Browsing follows the iOS appearance; tvOS retains its black presentation.
extension Color {
    static var browserBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        .black
        #endif
    }
    static var browserPanelBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        .black
        #endif
    }
}


struct RemoteSpeedTestSheet: View {
    let browser: Browser
    let entry: BrowserEntry
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64 = 0
    @State private var fraction = 0.0
    @State private var deadline: ContinuousClock.Instant?
    @State private var sample: RemoteSpeedTest.Sample?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Speed Test").font(.headline)
            Text(entry.name).lineLimit(2)
            if let sample {
                Text("\(sample.megabytesPerSecond, format: .number.precision(.fractionLength(2))) MB/s")
                    .font(.title)
                Text("\(sample.megabytesPerSecond * 8, format: .number.precision(.fractionLength(2))) Mbps")
                Text("\(sample.bytes.formatted()) bytes in \(sample.seconds, format: .number.precision(.fractionLength(3))) s")
            } else if let failure {
                Text("Speed test failed").font(.headline)
                Text(failure)
            } else if let deadline {
                ProgressView(value: fraction) {
                    Text("\(bytes.formatted()) bytes read")
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let remaining = ContinuousClock().now.duration(to: deadline)
                    let parts = remaining.components
                    let seconds = max(0, parts.seconds + (parts.attoseconds > 0 ? 1 : 0))
                    Text("\(seconds) s remaining").monospacedDigit()
                }
            } else {
                ProgressView("Connecting…")
            }
            Button(sample == nil && failure == nil ? "Cancel" : "Done") { dismiss() }
        }
        .multilineTextAlignment(.center)
        .padding(30)
        #if os(macOS)
        .frame(minWidth: 400)
        #endif
        .task {
            do {
                sample = try await browser.speedTest(entry) { count, progress, end in
                    bytes = count
                    fraction = progress
                    deadline = end
                }
            } catch {
                if !Task.isCancelled { failure = RemoteErrorMessage.message(for: error) }
            }
        }
    }
}
