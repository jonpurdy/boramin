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
    private var pendingSubtitle: SavedSubtitleSelection?
    private var latestSubtitle: SavedSubtitleSelection?
    private var missingSavedSubtitle = false
    private var onSubtitleChanged: ((SavedSubtitleSelection) -> Void)?

    convenience init(media: PreparedMedia) {
        self.init(subtitles: media.streaming?.externalSubtitles, backend: media.streaming?.aetherPlayback)
        if !CommandLine.arguments.contains("--no-playback-history"), let key = media.positionKey {
            configureBookmark(key: key, positions: .shared) { [weak media] in media?.subtitleSelection = $0 }
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
                self?.selectedAudio = backend?.engine.activeAudioTrackIndex
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
    }
    func selectAudio(_ id: Int) {
        guard !stopped, audio.contains(where: { $0.id == id && $0.supported }) else { return }
        if let backend { backend.engine.selectAudioTrack(index: id) }
        else if let group, options.indices.contains(id) { player?.currentItem?.select(options[id], in: group) }
        selectedAudio = id
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        task?.cancel(); task = nil; subscriptions.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if ownsSubtitles { subtitles.stop() }
        onSubtitleChanged = nil
        player = nil; group = nil; options = []
    }

    #if canImport(UIKit)
    var menuChanges: AnyPublisher<Void, Never> {
        Publishers.CombineLatest4($audio, $selectedAudio, subtitles.$embedded, subtitles.$selection)
            .map { _ in () }.eraseToAnyPublisher()
    }
    func menu() -> UIMenu {
        // AVKit's transport bar supports concrete UIAction children, not deferred
        // providers or nested section menus. Rebuild only when track state changes.
        let audio = self.audio.map { row in
            UIAction(title: "Audio: \(row.name)", identifier: UIAction.Identifier("boramin.audio.\(row.id)"),
                     attributes: row.supported ? [] : [.disabled], state: selectedAudio == row.id ? .on : .off) { [weak self] _ in self?.selectAudio(row.id) }
        }
        let options = [ExternalSubtitles.Option(id: "off", name: "Off")] + subtitles.embedded + subtitles.tracks.map { ExternalSubtitles.Option(id: "external:" + $0.id, name: $0.name) }
        let choices = options.map { row in
            UIAction(title: "Subtitles: \(row.name)", identifier: UIAction.Identifier("boramin.subtitles.\(row.id)"),
                     state: subtitles.selection == row.id ? .on : .off) { [weak self] _ in self?.subtitles.select(row.id) }
        }
        return UIMenu(title: "Audio & Subtitles", image: UIImage(systemName: "captions.bubble"),
                      identifier: UIMenu.Identifier("boramin.tracks"), children: audio + choices)
    }
    #endif
}

/// Like AetherPlayer: source tracks live in an app-written panel rather than
/// pretending external/libass tracks belong to AVPlayer's media-selection group.
struct PlaybackTracksPanel: View {
    @ObservedObject var tracks: PlaybackTracks
    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !tracks.audio.isEmpty {
                    Text("Audio").font(.headline)
                    audioRows
                    Divider()
                }
                Text("Subtitles").font(.headline)
                subtitleRows
                if tracks.subtitles.loading { ProgressView("Loading subtitles…").controlSize(.small) }
                if let error = tracks.subtitles.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.padding(16)
        }.frame(width: 340).frame(maxHeight: 440)
        #else
        List {
            if !tracks.audio.isEmpty { Section("Audio") { audioRows } }
            Section("Subtitles") {
                subtitleRows
                if tracks.subtitles.loading { ProgressView("Loading subtitles…") }
                if let error = tracks.subtitles.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        #endif
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
        Group {
            subtitleRow("Off", id: "off")
            ForEach(tracks.subtitles.embedded) { subtitleRow($0.name, id: $0.id) }
            ForEach(tracks.subtitles.tracks) { subtitleRow($0.name, id: "external:" + $0.id) }
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

struct PlaybackTracksButton: View {
    @ObservedObject var tracks: PlaybackTracks
    @State private var presented = false
    var onPresentationChanged: (Bool) -> Void = { _ in }
    var body: some View {
        #if os(tvOS)
        Menu {
            if !tracks.audio.isEmpty {
                Section("Audio") {
                    ForEach(tracks.audio) { row in
                        Button { tracks.selectAudio(row.id) } label: {
                            Label(row.name, systemImage: tracks.selectedAudio == row.id ? "checkmark.circle.fill" : "circle")
                        }.disabled(!row.supported)
                    }
                }
            }
            Section("Subtitles") {
                Button("Off") { tracks.subtitles.select("off") }
                ForEach(tracks.subtitles.embedded) { row in Button(row.name) { tracks.subtitles.select(row.id) } }
                ForEach(tracks.subtitles.tracks) { row in Button(row.name) { tracks.subtitles.select("external:" + row.id) } }
            }
        } label: { Label("Audio & Subtitles", systemImage: "captions.bubble") }
        #else
        Button { presented = true } label: { Label("Audio & Subtitles", systemImage: "captions.bubble") }
            #if os(macOS)
            .popover(isPresented: $presented, arrowEdge: .bottom) { PlaybackTracksPanel(tracks: tracks) }
            #else
            .sheet(isPresented: $presented) {
                NavigationStack {
                    PlaybackTracksPanel(tracks: tracks).navigationTitle("Audio & Subtitles")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = false } } }
                }.presentationDetents([.medium, .large])
            }
            #endif
            .onChange(of: presented) { _, value in onPresentationChanged(value) }
        #endif
    }
}
