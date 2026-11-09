import AVKit
import SwiftUI
import Combine
import AetherEngine

/// One source-track model for the app's sheet/popover and tvOS transport menu.
/// AVKit still owns video, transport, seeking and its built-in media groups.
@MainActor final class PlaybackTracks: ObservableObject {
    struct Audio: Identifiable {
        let id: Int
        let name: String
        let supported: Bool
    }
    @Published private(set) var audio: [Audio] = []
    @Published private(set) var selectedAudio: Int?
    let subtitles: ExternalSubtitles
    private let ownsSubtitles: Bool
    private weak var backend: AetherMKVPlayback?
    private weak var player: AVPlayer?
    private var group: AVMediaSelectionGroup?
    private var options: [AVMediaSelectionOption] = []
    private var subscriptions = Set<AnyCancellable>()
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var engineBound = false
    private var didBind = false
    private var savedAudio: SavedTrackSelection?
    private var onAudioChanged: ((SavedTrackSelection) -> Void)?
    private var pendingSubtitle: SavedSubtitleSelection?
    private var latestSubtitle: SavedSubtitleSelection?
    private var missingSavedSubtitle = false
    private var onSubtitleChanged: ((SavedSubtitleSelection) -> Void)?

    convenience init(media: PreparedMedia) {
        self.init(subtitles: media.streaming?.externalSubtitles, backend: media.streaming?.aetherPlayback)
        if !CommandLine.arguments.contains("--no-playback-history"), let key = media.positionKey {
            configureBookmark(key: key, positions: .shared) { [weak media] in media?.subtitleSelection = $0 }
            savedAudio = PlaybackPositions.shared.audioSelection(for: key)
            media.audioSelection = savedAudio
            onAudioChanged = { [weak media] selection in
                media?.audioSelection = selection
                PlaybackPositions.shared.saveAudio(selection, for: key)
            }
        }
    }
    init(subtitles: ExternalSubtitles?, backend: AetherMKVPlayback?) {
        self.backend = backend
        ownsSubtitles = subtitles == nil
        self.subtitles = subtitles ?? ExternalSubtitles(tracks: [])
        self.subtitles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        Publishers.CombineLatest3(self.subtitles.$selection, self.subtitles.$embedded, self.subtitles.$ready)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reconcileSubtitle() }.store(in: &subscriptions)
    }
    func configureBookmark(key: String, positions: PlaybackPositions, onChange: @escaping (SavedSubtitleSelection?) -> Void) {
        pendingSubtitle = positions.subtitleSelection(for: key)
        latestSubtitle = pendingSubtitle
        onChange(pendingSubtitle)
        onSubtitleChanged = { selection in
            onChange(selection)
            positions.saveSubtitle(selection, for: key)
        }
    }
    private func reconcileSubtitle() {
        guard !stopped, subtitles.ready else { return }
        if let pending = pendingSubtitle {
            pendingSubtitle = nil
            if let key = subtitles.restoredKey(for: pending) {
                missingSavedSubtitle = false; subtitles.select(key, explicit: false)
            } else {
                // Keep the saved identity for other devices, but don't substitute
                // an unrelated language or track when it is missing here.
                missingSavedSubtitle = true; subtitles.select("off", explicit: false)
            }
            return
        }
        guard latestSubtitle != nil || !subtitles.embedded.isEmpty || !subtitles.tracks.isEmpty else { return }
        guard !missingSavedSubtitle || subtitles.selectionIsExplicit,
              let selected = subtitles.savedSelection,
              selected.kind != .off || subtitles.selectionIsExplicit else { return }
        missingSavedSubtitle = false
        guard latestSubtitle != selected else { return }
        latestSubtitle = selected; onSubtitleChanged?(selected)
    }
    func bind(player: AVPlayer?) {
        guard !stopped else { return }
        if didBind { pendingSubtitle = latestSubtitle }
        didBind = true
        self.player = player
        subtitles.bind(player: player, backend: backend)
        if let backend {
            // Audio switches may replace AVPlayerItem. Engine track IDs remain
            // authoritative, so this model does not retain the old native item.
            guard !engineBound else { return }; engineBound = true
            backend.engine.$audioTracks.receive(on: DispatchQueue.main).sink { [weak self] tracks in
                self?.audio = tracks.map { Audio(id: $0.id, name: "\($0.name) — \($0.codec.uppercased())", supported: true) }
            }.store(in: &subscriptions)
            backend.engine.$activeAudioTrackIndex.receive(on: DispatchQueue.main).sink { [weak self, weak backend] _ in
                guard let self, !self.stopped else { return }
                self.selectedAudio = backend?.engine.activeAudioTrackIndex
                if let track = backend?.engine.audioTracks.first(where: { $0.id == self.selectedAudio }) {
                    self.recordAudio(SavedTrackSelection(kind: .engine, stream: track.id, name: track.name,
                                                         language: track.language, codec: track.codec))
                }
            }.store(in: &subscriptions)
        } else if let item = player?.currentItem {
            task?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            task = Task { [weak self, weak item] in
                guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), !Task.isCancelled,
                      let self, !self.stopped else { return }
                self.group = group; self.options = group.options
                let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
                let decoders = NativeAudioSelection.decoderIDs()
                self.audio = group.options.enumerated().map { index, option in
                    let supported = playable.contains(option) && option.mediaSubTypes.contains { decoders.contains($0.uint32Value) }
                    return Audio(id: index, name: option.displayName + (supported ? "" : " (Unsupported)"), supported: supported)
                }
                if let saved = self.savedAudio, saved.kind == .native, let data = saved.nativePropertyList,
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                   let option = group.mediaSelectionOption(withPropertyList: plist), playable.contains(option) {
                    item.select(option, in: group)
                }
                self.refreshAudio()
                self.observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAudio() }
                }
            }
        }
    }
    private func refreshAudio() {
        guard let group, let selected = player?.currentItem?.currentMediaSelection.selectedMediaOption(in: group) else { selectedAudio = nil; return }
        selectedAudio = options.firstIndex(of: selected)
        let plist = try? PropertyListSerialization.data(fromPropertyList: selected.propertyList(), format: .binary, options: 0)
        recordAudio(SavedTrackSelection(kind: .native, name: selected.displayName, nativePropertyList: plist))
    }
    private func recordAudio(_ selection: SavedTrackSelection) {
        guard selection != savedAudio else { return }
        savedAudio = selection
        onAudioChanged?(selection)
    }

    func selectAudio(_ id: Int) {
        guard !stopped, audio.contains(where: { $0.id == id && $0.supported }) else { return }
        if let backend { backend.engine.selectAudioTrack(index: id) }
        else if let group, options.indices.contains(id) {
            player?.currentItem?.select(options[id], in: group)
            refreshAudio()
        }
        selectedAudio = id
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        task?.cancel(); task = nil; subscriptions.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if ownsSubtitles { subtitles.stop() }
        onSubtitleChanged = nil
        onAudioChanged = nil
        player = nil; group = nil; options = []
    }

    var hasSourceAudioChoices: Bool { backend != nil && !audio.isEmpty }
    var hasAppSubtitleChoices: Bool {
        !subtitles.tracks.isEmpty || (backend != nil && !subtitles.embedded.isEmpty)
    }

    var subtitleOptions: [ExternalSubtitles.Option] {
        [ExternalSubtitles.Option(id: "off", name: "Off")] + subtitles.embedded
            + subtitles.tracks.map { ExternalSubtitles.Option(id: "external:" + $0.id, name: $0.name) }
    }

    #if canImport(UIKit)
    var menuChanges: AnyPublisher<Void, Never> {
        Publishers.CombineLatest4($audio, $selectedAudio, subtitles.$embedded, subtitles.$selection)
            .map { _ in () }.eraseToAnyPublisher()
    }
    func trackMenus(includeSubtitles: Bool) -> [UIMenu] {
        // AVKit's transport bar supports concrete UIAction children, not deferred
        // providers or nested section menus. Rebuild only when track state changes.
        let audio = self.audio.map { row in
            UIAction(title: row.name, identifier: UIAction.Identifier("boramin.audio.\(row.id)"),
                     attributes: row.supported ? [] : [.disabled], state: selectedAudio == row.id ? .on : .off) { [weak self] _ in self?.selectAudio(row.id) }
        }
        var menus: [UIMenu] = []
        if !audio.isEmpty {
            menus.append(UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"),
                                identifier: UIMenu.Identifier("boramin.audio"), children: audio))
        }
        if includeSubtitles {
            let choices = subtitleOptions.map { row in
                UIAction(title: row.name, identifier: UIAction.Identifier("boramin.subtitles.\(row.id)"),
                         state: subtitles.selection == row.id ? .on : .off) { [weak self] _ in self?.subtitles.select(row.id) }
            }
            menus.append(UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"),
                                identifier: UIMenu.Identifier("boramin.subtitles"), children: choices))
        }
        return menus
    }
    #endif
}

#if !os(tvOS)
private enum TrackMenu: String, Identifiable {
    case audio = "Audio"
    case subtitles = "Subtitles"

    var id: Self { self }
    var symbol: String { self == .audio ? "speaker.wave.2" : "captions.bubble" }
}

private struct PlaybackTracksPanel: View {
    @ObservedObject var tracks: PlaybackTracks
    let menu: TrackMenu

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(menu.rawValue).font(.headline)
                rows
            }.padding(16)
        }.frame(width: 340).frame(maxHeight: 440)
        #else
        List { rows }
        #endif
    }

    @ViewBuilder private var rows: some View {
        switch menu {
        case .audio:
            audioRows
        case .subtitles:
            subtitleRows
            if tracks.subtitles.loading { ProgressView("Loading subtitles…") }
            if let error = tracks.subtitles.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var audioRows: some View {
        ForEach(tracks.audio) { row in
            Button { tracks.selectAudio(row.id) } label: { rowLabel(row.name, selected: tracks.selectedAudio == row.id) }
                .disabled(!row.supported)
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
        }
    }
    private var subtitleRows: some View {
        ForEach(tracks.subtitleOptions) { row in
            subtitleRow(row.name, id: row.id)
        }
    }
    private func subtitleRow(_ title: String, id: String) -> some View {
        Button { tracks.subtitles.select(id) } label: { rowLabel(title, selected: tracks.subtitles.selection == id) }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
    }
    private func rowLabel(_ title: String, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#endif

struct PlaybackMenuButtons: View {
    @ObservedObject var tracks: PlaybackTracks
    @AppStorage("showDebugInfo") private var showDebugInfo = false
    var onDebugChanged: (Bool) -> Void
    var body: some View {
        HStack {
            PlaybackTracksButton(tracks: tracks, supplementalOnly: true)
            Menu {
                Toggle("Show Debug Info", isOn: $showDebugInfo)
            } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
        }
        .onChange(of: showDebugInfo) { _, enabled in onDebugChanged(enabled) }
    }
}

struct PlaybackTracksButton: View {
    @ObservedObject var tracks: PlaybackTracks
    #if !os(tvOS)
    @State private var presented: TrackMenu?
    #endif
    var supplementalOnly = false
    var onPresentationChanged: (Bool) -> Void = { _ in }
    var body: some View {
        #if os(tvOS)
        TVPlaybackTrackMenus(tracks: tracks).equatable()
        #else
        HStack {
            if supplementalOnly ? tracks.hasSourceAudioChoices : !tracks.audio.isEmpty { trackButton(.audio) }
            if !supplementalOnly || tracks.hasAppSubtitleChoices { trackButton(.subtitles) }
        }
        #if os(iOS)
        .sheet(item: $presented) { menu in
            NavigationStack {
                PlaybackTracksPanel(tracks: tracks, menu: menu).navigationTitle(menu.rawValue)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = nil } } }
            }.presentationDetents([.medium, .large])
        }
        #endif
        .onChange(of: presented != nil) { _, visible in onPresentationChanged(visible) }
        #endif
    }

    #if !os(tvOS)
    private func trackButton(_ menu: TrackMenu) -> some View {
        Button { presented = menu } label: {
            Label(menu.rawValue, systemImage: menu.symbol).labelStyle(.iconOnly)
        }
        .accessibilityLabel(menu.rawValue)
        #if os(macOS)
        .popover(isPresented: Binding(get: { presented == menu }, set: { visible in
            if !visible && presented == menu { presented = nil }
        }), arrowEdge: .bottom) {
            PlaybackTracksPanel(tracks: tracks, menu: menu)
        }
        #endif
    }
    #endif
}

#if os(tvOS)
/// Keep the presented menus stable while playback position or subtitle pixels update.
private struct TVPlaybackTrackMenus: View, Equatable {
    private struct Row<ID: Hashable>: Identifiable, Equatable {
        let id: ID
        let title: String
        let selected: Bool
        var supported = true
    }

    private let tracks: PlaybackTracks
    private let audio: [Row<Int>]
    private let subtitles: [Row<String>]

    init(tracks: PlaybackTracks) {
        self.tracks = tracks
        audio = tracks.audio.map {
            Row(id: $0.id, title: $0.name, selected: tracks.selectedAudio == $0.id, supported: $0.supported)
        }
        subtitles = tracks.subtitleOptions.map {
            Row(id: $0.id, title: $0.name, selected: tracks.subtitles.selection == $0.id)
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tracks === rhs.tracks && lhs.audio == rhs.audio && lhs.subtitles == rhs.subtitles
    }

    var body: some View {
        HStack(spacing: 8) {
            if !audio.isEmpty {
                Menu {
                    ForEach(audio) { row in
                        Button { tracks.selectAudio(row.id) } label: { trackLabel(row) }
                            .disabled(!row.supported)
                    }
                } label: {
                    Label("Audio", systemImage: "speaker.wave.2").labelStyle(.iconOnly)
                }
                .accessibilityLabel("Audio")
            }
            Menu {
                ForEach(subtitles) { row in
                    Button { tracks.subtitles.select(row.id) } label: { trackLabel(row) }
                }
            } label: {
                Label("Subtitles", systemImage: "captions.bubble").labelStyle(.iconOnly)
            }
            .accessibilityLabel("Subtitles")
        }
    }

    private func trackLabel<ID>(_ row: Row<ID>) -> some View {
        HStack {
            Text(row.title)
            if row.selected { Image(systemName: "checkmark") }
        }
    }
}
#endif
