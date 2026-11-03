import Foundation
import AVKit
import SwiftUI
import Combine
import AMSMB2
import AetherEngine
import SwiftAssRenderer
import OSLog

private let externalSubtitleLog = Logger(subsystem: "com.example.BoraMin", category: "Subtitles")

@MainActor final class ExternalSubtitles: ObservableObject {
    struct Track: Identifiable {
        let id: String
        let name: String
        let ext: String
        let load: @Sendable (CancellationFlag) async throws -> Data
    }
    struct Option: Identifiable { let id: String; let name: String }
    let tracks: [Track]
    @Published private(set) var selection = "off"
    @Published private(set) var embedded: [Option] = []
    @Published private(set) var frame: ProcessedImage?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var ready = false
    private(set) var selectionIsExplicit = false
    var externalSelected: Bool { selection.hasPrefix("external:") }
    private weak var backend: AetherMKVPlayback?
    private weak var player: AVPlayer?
    private var nativeGroup: AVMediaSelectionGroup?
    private var nativeOptions: [AVMediaSelectionOption] = []
    private var clockToken: Any?
    private var selectionObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var cancellation = CancellationFlag()
    private var rasterizer: ASSRasterizer?
    private var document: ExternalSubtitleDecoder.Document?
    private var generation: UInt64 = 0
    private var time = 0.0
    private var canvas = CGSize.zero
    private var scale: CGFloat = 1
    private var fontScale = 1.25
    private var stopped = false
    private var changingNativeSelection = false
    private var awaitingNativeOff = false

    init(tracks: [Track], appearance: SubtitleAppearance = .shared) {
        self.tracks = tracks
        fontScale = appearance.fontScale
        appearance.$percent.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.fontScale = Double(value) / 100; self?.render()
        }.store(in: &appearanceSubscriptions)
    }
    private var appearanceSubscriptions = Set<AnyCancellable>()

    static func matches(videoName: String, subtitleName: String) -> Bool {
        ExternalSubtitleFiles.matches(videoName: videoName, subtitleName: subtitleName)
    }

    static func discover(session: RemoteSession, path: String, playbackCancellation: CancellationFlag) async -> ExternalSubtitles? {
        do {
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let entries = try await session.readDirectory(path: folder)
            guard !playbackCancellation.cancelled, !Task.isCancelled else { return nil }
            let tracks: [Track] = entries.compactMap { entry in
                guard !entry.directory,
                      let match = ExternalSubtitleFiles.match(videoName: name, subtitleName: entry.name) else { return nil }
                let size = entry.size, remotePath = entry.path
                let ext = match.ext
                return Track(id: remotePath, name: match.menuName(), ext: ext) { cancellation in
                    guard size > 0, size <= ExternalSubtitleDecoder.maximumBytes else { throw PlayerError("The subtitle file is empty or exceeds 8 MiB.") }
                    if let client = session.smb {
                        // Preserve the SMB sidecar read, including its size-change check.
                        var bytes = Data()
                        for try await chunk in client.contents(atPath: remotePath, range: Int64(0)..<(size + 1)) {
                            guard !cancellation.cancelled, !playbackCancellation.cancelled, !Task.isCancelled else { throw CancellationError() }
                            guard bytes.count + chunk.count <= size else { throw PlayerError("The subtitle file changed while loading.") }
                            bytes.append(chunk)
                        }
                        guard bytes.count == size else { throw PlayerError("The subtitle download ended early.") }
                        return bytes
                    }
                    let source = try await session.openFile(path: remotePath, size: size, cancellation: playbackCancellation)
                    return try await Task.detached(priority: .userInitiated) {
                        var bytes = Data()
                        while bytes.count < size {
                            guard !cancellation.cancelled, !playbackCancellation.cancelled, !Task.isCancelled else { throw CancellationError() }
                            let chunk = try source.read(offset: Int64(bytes.count), count: Int(size) - bytes.count, interrupt: cancellation)
                            guard !chunk.isEmpty else { throw PlayerError("The subtitle download ended early.") }
                            bytes.append(chunk)
                        }
                        return bytes
                    }.value
                }
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            externalSubtitleLog.notice("Matching external subtitle files=\(tracks.count)")
            return tracks.isEmpty ? nil : ExternalSubtitles(tracks: tracks)
        } catch {
            externalSubtitleLog.warning("Subtitle discovery failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func bind(player: AVPlayer?, backend: AetherMKVPlayback?) {
        guard !stopped else { return }
        unbind()
        ready = false
        self.player = player; self.backend = backend
        update(time: backend?.engine.sourceTime ?? player?.currentTime().seconds ?? 0)
        if let backend {
            backend.engine.$subtitleTracks.receive(on: DispatchQueue.main).sink { [weak self] tracks in
                self?.embedded = tracks.map { Option(id: "embedded:\($0.id)", name: "\($0.name) — \($0.codec.uppercased())") }
                self?.ready = true
            }.store(in: &subscriptions)
            backend.engine.$activeSubtitleTrackIndex.receive(on: DispatchQueue.main).sink { [weak self, weak backend] _ in
                guard let self else { return }
                let id = backend?.engine.activeSubtitleTrackIndex
                if let id, id >= 0 { self.clearExternal(); self.selection = "embedded:\(id)" }
                else if !self.externalSelected {
                    if self.selection != "off" { self.selectionIsExplicit = false }
                    self.selection = "off"
                }
            }.store(in: &subscriptions)
            backend.engine.clock.$sourceTime.receive(on: DispatchQueue.main).sink { [weak self] time in self?.update(time: time) }.store(in: &subscriptions)
        } else if let player, let item = player.currentItem {
            if !tracks.isEmpty { clockToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.update(time: time.seconds) }
            } }
            groupTask = Task { [weak self, weak item] in
                do {
                    guard let item else { return }
                    let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
                    guard !Task.isCancelled, let self, !self.stopped else { return }
                    guard let group = loadedGroup else { self.ready = true; return }
                    self.nativeGroup = group; self.nativeOptions = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
                    self.embedded = self.nativeOptions.enumerated().map { Option(id: "embedded:\($0.offset)", name: $0.element.displayName) }
                    if self.externalSelected { self.selectNative(nil) }
                    else { self.nativeSelectionChanged(initial: true) }
                    self.selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.nativeSelectionChanged() }
                    }
                    self.ready = true
                } catch {
                    if !Task.isCancelled { self?.ready = true }
                    externalSubtitleLog.warning("Embedded subtitle menu unavailable: \(error.localizedDescription, privacy: .private)")
                }
            }
        } else { ready = true }
    }
    private func nativeSelectionChanged(initial: Bool = false) {
        guard !changingNativeSelection else { return }
        guard let item = player?.currentItem, let group = nativeGroup else { return }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        if awaitingNativeOff {
            if selected == nil { awaitingNativeOff = false }
            return
        }
        if let selected, let index = nativeOptions.firstIndex(of: selected) {
            if !initial { selectionIsExplicit = true }
            clearExternal(); selection = "embedded:\(index)"
        } else if !externalSelected {
            if !initial && selection != "off" { selectionIsExplicit = true }
            selection = "off"
        }
    }
    private func selectNative(_ option: AVMediaSelectionOption?) {
        guard let group = nativeGroup else { return }
        // AVPlayer can post its notification synchronously during select(), while
        // currentMediaSelection still reports the previous option.
        if option == nil && externalSelected { awaitingNativeOff = true }
        changingNativeSelection = true
        player?.currentItem?.select(option, in: group)
        changingNativeSelection = false
    }
    func select(_ key: String, explicit: Bool = true) {
        guard !stopped else { return }
        selectionIsExplicit = explicit
        player?.appliesMediaSelectionCriteriaAutomatically = false
        clearExternal()
        selection = key
        if key.hasPrefix("external:"), let track = tracks.first(where: { "external:" + $0.id == key }) {
            backend?.selectSubtitle(index: -1)
            backend?.engine.setNativeSubtitleRendering(false)
            player?.appliesMediaSelectionCriteriaAutomatically = false
            selectNative(nil)
            loading = true
            let version = generation, cancellation = cancellation
            loadTask = Task { [weak self] in
                do {
                    let bytes = try await track.load(cancellation)
                    let document = try await Task.detached(priority: .userInitiated) {
                        try ExternalSubtitleDecoder.decode(bytes, extension: track.ext, cancellation: cancellation)
                    }.value
                    guard !cancellation.cancelled, !Task.isCancelled else { throw CancellationError() }
                    let fonts = self?.backend?.engine.fontAttachments ?? []
                    let rasterizer = try await Task.detached(priority: .userInitiated) {
                        try ASSRasterizer(header: document.header, fonts: fonts, cancellation: cancellation)
                    }.value
                    guard let self, !self.stopped, self.generation == version, !cancellation.cancelled else { rasterizer.stop(); return }
                    self.document = document; self.rasterizer = rasterizer; self.loading = false
                    if let group = self.nativeGroup, self.player?.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == nil { self.awaitingNativeOff = false }
                    self.render()
                    externalSubtitleLog.notice("External subtitle ready format=\(track.ext, privacy: .public) cues=\(document.cues.count)")
                } catch {
                    guard let self, !self.stopped, self.generation == version, !cancellation.cancelled else { return }
                    self.loading = false; self.error = error.localizedDescription
                    externalSubtitleLog.error("External subtitle failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        } else {
            let index = key.hasPrefix("embedded:") ? Int(key.dropFirst("embedded:".count)) : nil
            if let backend {
                backend.selectSubtitle(index: index ?? -1)
                backend.engine.setNativeSubtitleRendering(!backend.usesSubtitleOverlay)
            }
            else if nativeGroup != nil {
                let option = index.flatMap { nativeOptions.indices.contains($0) ? nativeOptions[$0] : nil }
                selectNative(option)
            }
        }
    }
    var savedSelection: SavedSubtitleSelection? {
        if externalSelected, let track = tracks.first(where: { "external:" + $0.id == selection }) {
            return SavedSubtitleSelection(kind: .external, filename: (track.id as NSString).lastPathComponent)
        }
        if selection == "off" { return SavedSubtitleSelection(kind: .off) }
        guard let index = Int(selection.dropFirst("embedded:".count)) else { return nil }
        if let backend, let track = backend.engine.subtitleTracks.first(where: { $0.id == index }) {
            return SavedSubtitleSelection(kind: .engine, stream: track.id, name: track.name, language: track.language, codec: track.codec)
        }
        guard nativeOptions.indices.contains(index) else { return nil }
        let option = nativeOptions[index]
        let plist = try? PropertyListSerialization.data(fromPropertyList: option.propertyList(), format: .binary, options: 0)
        return SavedSubtitleSelection(kind: .native, name: option.displayName,
            language: option.extendedLanguageTag ?? option.locale?.identifier, nativePropertyList: plist,
            nativeSubtypes: option.mediaSubTypes.map(\.uint32Value), forced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
    }
    /// nil means unavailable, never "pick the first track".
    func restoredKey(for saved: SavedSubtitleSelection) -> String? {
        switch saved.kind {
        case .off: return "off"
        case .external:
            return tracks.first { ($0.id as NSString).lastPathComponent == saved.filename }.map { "external:" + $0.id }
        case .engine:
            guard let track = backend?.engine.subtitleTracks.first(where: {
                $0.id == saved.stream && $0.codec == saved.codec && $0.language == saved.language && $0.name == saved.name
            }) else { return nil }
            return "embedded:\(track.id)"
        case .native:
            if let data = saved.nativePropertyList, let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let option = nativeGroup?.mediaSelectionOption(withPropertyList: plist), let index = nativeOptions.firstIndex(of: option) {
                return "embedded:\(index)"
            }
            let matching = nativeOptions.enumerated().filter { _, option in
                (option.extendedLanguageTag ?? option.locale?.identifier) == saved.language &&
                option.mediaSubTypes.map(\.uint32Value) == saved.nativeSubtypes &&
                option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) == saved.forced
            }
            let named = matching.filter { $0.element.displayName == saved.name }
            if named.count == 1 { return "embedded:\(named[0].offset)" }
            return matching.count == 1 ? "embedded:\(matching[0].offset)" : nil
        }
    }
    func setCanvas(_ size: CGSize, scale: CGFloat) { canvas = size; self.scale = max(1, scale); render() }
    func update(time: Double) { guard time.isFinite else { return }; self.time = time; render() }
    private func render() {
        guard !stopped, externalSelected, let rasterizer, let document else { return }
        let version = generation, requestedTime = time, requestedCanvas = canvas, requestedScale = scale, requestedFontScale = fontScale
        rasterizer.render(cues: document.cues, revision: version, time: time, size: canvas, scale: scale, fontScale: fontScale) { [weak self] output in
            guard let self, !self.stopped, self.generation == version else { return }
            switch output { case .unchanged: break; case .clear: self.frame = nil; case .frame(let frame): self.frame = frame }
            // Coalesce a seek/resize that arrived while the shared worker was
            // busy. A paused player need not send another clock tick afterwards.
            if self.time != requestedTime || self.canvas != requestedCanvas || self.scale != requestedScale || self.fontScale != requestedFontScale {
                Task { @MainActor [weak self] in self?.render() }
            }
        }
    }
    private func clearExternal() {
        generation &+= 1; cancellation.cancel(); loadTask?.cancel(); loadTask = nil
        cancellation = CancellationFlag(); rasterizer?.stop(); rasterizer = nil
        document = nil; frame = nil; error = nil; loading = false; awaitingNativeOff = false
    }
    private func unbind() {
        groupTask?.cancel(); groupTask = nil; subscriptions.removeAll()
        if let clockToken { player?.removeTimeObserver(clockToken); self.clockToken = nil }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver); self.selectionObserver = nil }
        nativeGroup = nil; nativeOptions = []; embedded = []
    }
    func stop() { guard !stopped else { return }; stopped = true; clearExternal(); unbind(); appearanceSubscriptions.removeAll(); player = nil; backend = nil }

}

/// One overlay root for both player hosts; external selection takes precedence
/// over the existing embedded renderer, without changing the video route.
struct PlaybackSubtitleOverlay: View {
    let media: PreparedMedia
    var controlsVisible = false
    var videoRect: CGRect? = nil
    var body: some View {
        if let subtitles = media.streaming?.externalSubtitles {
            ExternalOrEmbeddedSubtitles(subtitles: subtitles, media: media, controlsVisible: controlsVisible, videoRect: videoRect)
        } else if let backend = media.streaming?.aetherPlayback {
            AetherSubtitleOverlay(backend: backend, controlsVisible: controlsVisible, videoRect: videoRect)
        }
    }
}

private struct ExternalOrEmbeddedSubtitles: View {
    @ObservedObject var subtitles: ExternalSubtitles
    let media: PreparedMedia
    let controlsVisible: Bool
    let videoRect: CGRect?
    @Environment(\.displayScale) private var scale
    var body: some View {
        if subtitles.externalSelected {
            GeometryReader { geometry in
                let rect = videoRect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? AVMakeRect(aspectRatio: CGSize(width: max(1, Int(media.info.width)), height: max(1, Int(media.info.height))), insideRect: CGRect(origin: .zero, size: geometry.size))
                ZStack(alignment: .topLeading) {
                    if let frame = subtitles.frame {
                        Image(decorative: frame.image, scale: scale).resizable()
                            .frame(width: frame.imageRect.width, height: frame.imageRect.height)
                            .position(x: frame.imageRect.midX, y: frame.imageRect.midY)
                    }
                    if let error = subtitles.error { Text("Subtitles: \(error)").font(.caption).padding(8).background(.black.opacity(0.65)) }
                }
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .onAppear { subtitles.setCanvas(rect.size, scale: scale) }
                .onChange(of: rect.size) { _, size in subtitles.setCanvas(size, scale: scale) }
                .onChange(of: scale) { _, value in subtitles.setCanvas(rect.size, scale: value) }
            }.clipped().allowsHitTesting(false)
        } else if let backend = media.streaming?.aetherPlayback {
            AetherSubtitleOverlay(backend: backend, controlsVisible: controlsVisible, videoRect: videoRect)
        }
    }
}

#if os(macOS)
final class PlaybackSubtitleHostingView: NSHostingView<PlaybackSubtitleOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
