#if canImport(SwiftAssRenderer) && canImport(AetherEngine)
import Foundation
import SwiftUI
import Combine
import CoreGraphics
import AVFoundation
import AetherEngine
import SwiftAssRenderer
import SwiftLibass
import OSLog

private let assLog = Logger(subsystem: BoraMinIdentity.bundleIdentifier, category: "Subtitles")

/// All libass pointers and bitmap processing stay on one queue. Compressed events
/// are appended through the public Matroska API, rather than reparsing whole scripts.
final class ASSRasterizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: BoraMinIdentity.bundleIdentifier + ".libass", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let gate = NSLock()
    private var rendering = false
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var stopped = false
    private var seen = Set<String>()
    private var lastTime = -1.0
    private var lastReset = -1.0
    private var lastSize = CGSize.zero
    private var lastCueRevision = UInt64.max
    private var lastFontScale = 0.0
    private let pipeline = BlendImagePipeline()
    enum Output { case unchanged, clear, frame(ProcessedImage) }

    init(header: String, fonts: [FontAttachment], cancellation: CancellationFlag? = nil) throws {
        queue.setSpecific(key: queueKey, value: true)
        try queue.sync {
            if cancellation?.cancelled == true { throw CancellationError() }
            guard header.utf8.count <= Int(Int32.max) else { throw PlayerError("Subtitle style header is too large.") }
            guard let library = ass_library_init() else { throw PlayerError("Could not initialize libass.") }
            self.library = library
            ass_set_extract_fonts(library, 1)
            for font in fonts where !font.data.isEmpty && font.data.count <= Int(Int32.max) {
                if cancellation?.cancelled == true { throw CancellationError() }
                font.data.withUnsafeBytes { bytes in
                    font.filename.withCString { name in
                        ass_add_font(library, name, bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count))
                    }
                }
            }
            guard let renderer = ass_renderer_init(library) else { throw PlayerError("Could not initialize subtitle rendering.") }
            self.renderer = renderer
            ass_set_fonts(renderer, nil, "sans-serif", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
            ass_set_cache_limits(renderer, 1000, 32)
            guard let track = ass_new_track(library) else { throw PlayerError("Could not initialize the subtitle track.") }
            self.track = track
            let clean = header.replacingOccurrences(of: "\0", with: "")
            clean.withCString { ass_process_codec_private(track, $0, Int32(clean.utf8.count)) }
            // Some files reuse ReadOrder=0 for every line. Deduplicate by full event + time instead.
            ass_set_check_readorder(track, 0)
        }
    }
    func render(cues: [SubtitleCue], revision: UInt64, time: Double, size: CGSize, scale: CGFloat, fontScale: Double = 1,
                completion: @escaping @MainActor (Output) -> Void) {
        guard time.isFinite, time >= 0, size.width > 0, size.height > 0 else { return }
        gate.lock()
        guard !rendering else { gate.unlock(); return }
        rendering = true; gate.unlock()
        queue.async { [self] in
            var output: Output = .unchanged
            if !stopped, let renderer, let track {
                let renderScale = min(scale, 8192 / max(size.width, size.height))
                let canvas = CGSize(width: max(1, (size.width * renderScale).rounded()), height: max(1, (size.height * renderScale).rounded()))
                let factor = fontScale.isFinite ? min(2, max(1, fontScale)) : 1
                let fontChanged = factor != lastFontScale
                if fontChanged { ass_set_font_scale(renderer, factor); lastFontScale = factor }
                let resized = canvas != lastSize
                if resized { ass_set_frame_size(renderer, Int32(canvas.width), Int32(canvas.height)); lastSize = canvas }
                // Keep event storage bounded, and rebuild from the engine's current cue window on seeks.
                let reset = lastReset < 0 || time < lastTime - 0.5 || time > lastTime + 5 || time - lastReset > 60 || seen.count > 10000
                if reset { ass_flush_events(track); seen.removeAll(keepingCapacity: true); lastReset = time }
                lastTime = time
                var added = false
                if reset || revision != lastCueRevision {
                    lastCueRevision = revision
                    for cue in cues where cue.endTime >= time - 30 && cue.startTime <= time + 180 {
                        guard case .text(let raw) = cue.body else { continue }
                        for line in raw.split(separator: "\n") {
                            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                            guard fields.count == 9, Int(fields[0]) != nil else { continue }
                            let key = "\(cue.startTime)|\(cue.endTime)|\(line)"
                            guard seen.insert(key).inserted else { continue }
                            let text = String(line)
                            let start = Int64(max(0, cue.startTime) * 1000)
                            let duration = Int64(max(0, cue.endTime - cue.startTime) * 1000)
                            text.withCString { ass_process_chunk(track, $0, Int32(text.utf8.count), start, duration) }
                            added = true
                        }
                    }
                }
                var changed: Int32 = 0
                let first = ass_render_frame(renderer, track, Int64(time * 1000), &changed)
                if changed != 0 || resized || fontChanged || added || reset {
                    if let first {
                        let images = linkedImages(from: first.pointee).filter { $0.w > 0 && $0.h > 0 }
                        let rect = imagesBoundingRect(images: images)
                        // Avoid allocations for corrupt, unbounded drawing coordinates.
                        if rect.width > 0, rect.height > 0, rect.width <= 16384, rect.height <= 16384,
                           rect.width * rect.height <= 33_554_432,
                           let result = pipeline.process(images: images, boundingRect: rect) {
                            let logical = CGRect(x: rect.minX / renderScale, y: rect.minY / renderScale, width: rect.width / renderScale, height: rect.height / renderScale)
                            output = .frame(ProcessedImage(image: result.image, imageRect: logical))
                        } else { output = .clear }
                    } else { output = .clear }
                }
            }
            let result = output
            Task { @MainActor [self] in
                completion(result)
                self.finishRendering()
            }
        }
    }
    private func finishRendering() { gate.lock(); rendering = false; gate.unlock() }
    func stop() { queue.async { [self] in releaseResources() } }
    private func releaseResources() {
        stopped = true
        if let track { ass_free_track(track); self.track = nil }
        if let renderer { ass_renderer_done(renderer); self.renderer = nil }
        if let library { ass_library_done(library); self.library = nil }
        seen.removeAll()
    }
    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { releaseResources() }
        else { queue.sync { releaseResources() } }
    }
}

@MainActor final class StyledASSCoordinator: ObservableObject {
    @Published private(set) var frame: ProcessedImage?
    @Published private(set) var active = false
    @Published private(set) var error: String?
    let engine: AetherEngine
    private var rasterizer: ASSRasterizer?
    private var subscriptions = Set<AnyCancellable>()
    private var selectedID: Int?
    private var canvas = CGSize.zero
    private var scale: CGFloat = 1
    private var generation = 0
    private var cueRevision: UInt64 = 0
    private var fontScale = 1.25
    private var stopped = false
    private var setupTask: Task<Void, Never>?
    private var setupCancellation = CancellationFlag()
    init(engine: AetherEngine, appearance: SubtitleAppearance = .shared) {
        self.engine = engine
        fontScale = appearance.fontScale
        appearance.$percent.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.fontScale = Double(value) / 100; self?.render()
        }.store(in: &subscriptions)
        engine.$activeSubtitleTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &subscriptions)
        engine.$subtitleTracks.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &subscriptions)
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }; self.cueRevision &+= 1; self.render()
        }.store(in: &subscriptions)
        engine.clock.$sourceTime.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        updateSelection()
    }
    static func isASS(_ codec: String) -> Bool { ["ass", "ssa"].contains(codec.lowercased()) }
    func setCanvas(_ size: CGSize, scale: CGFloat) {
        guard !stopped else { return }
        canvas = size; self.scale = max(1, scale); render()
    }
    private func updateSelection() {
        guard !stopped else { return }
        let track = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        let id = track.flatMap { Self.isASS($0.codec) ? $0.id : nil }
        guard selectedID != id else { return }
        generation += 1; setupCancellation.cancel(); setupTask?.cancel()
        setupCancellation = CancellationFlag()
        rasterizer?.stop(); rasterizer = nil; frame = nil; error = nil
        selectedID = id; active = id != nil
        guard let track, id != nil else { return }
        guard let header = track.assHeader, !header.isEmpty else {
            error = "The ASS subtitle style header is missing."; return
        }
        let fonts = engine.fontAttachments
        let currentGeneration = generation
        let cancellation = setupCancellation
        setupTask = Task { @MainActor [weak self] in
            do {
                let rasterizer = try await Task.detached(priority: .userInitiated) {
                    try ASSRasterizer(header: header, fonts: fonts, cancellation: cancellation)
                }.value
                guard let self, !self.stopped, !Task.isCancelled, self.generation == currentGeneration else { rasterizer.stop(); return }
                self.rasterizer = rasterizer
                assLog.notice("Styled subtitle renderer opened track=\(track.id) embeddedFonts=\(fonts.count)")
                self.render()
            } catch {
                guard let self, !self.stopped, !cancellation.cancelled, self.generation == currentGeneration else { return }
                self.error = error.localizedDescription
                assLog.error("Styled subtitles failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    private func render() {
        guard !stopped, let rasterizer else { return }
        let currentGeneration = generation, requestedTime = engine.sourceTime, requestedCanvas = canvas, requestedScale = scale, requestedFontScale = fontScale
        rasterizer.render(cues: engine.subtitleCues, revision: cueRevision, time: engine.sourceTime, size: canvas, scale: scale, fontScale: fontScale) { [weak self] result in
            guard let self, !self.stopped, self.generation == currentGeneration else { return }
            switch result {
            case .unchanged: break
            case .clear: self.frame = nil
            case .frame(let frame): self.frame = frame
            }
            if self.engine.sourceTime != requestedTime || self.canvas != requestedCanvas || self.scale != requestedScale || self.fontScale != requestedFontScale {
                Task { @MainActor [weak self] in self?.render() }
            }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; generation += 1; subscriptions.removeAll()
        setupCancellation.cancel(); setupTask?.cancel(); setupTask = nil
        rasterizer?.stop(); rasterizer = nil; frame = nil
    }
}

/// Shared by native AVKit overlays and AetherEngine's software player.
struct StyledASSOverlay: View {
    @ObservedObject var coordinator: StyledASSCoordinator
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let frame = coordinator.frame {
                    Image(decorative: frame.image, scale: displayScale)
                        .resizable().frame(width: frame.imageRect.width, height: frame.imageRect.height)
                        .position(x: frame.imageRect.midX, y: frame.imageRect.midY)
                }
                if let error = coordinator.error {
                    Text("Subtitles: \(error)").font(.caption).padding(8).background(.black.opacity(0.65))
                }
            }
            .onAppear { coordinator.setCanvas(geometry.size, scale: displayScale) }
            .onChange(of: geometry.size) { _, size in coordinator.setCanvas(size, scale: displayScale) }
            .onChange(of: displayScale) { _, scale in coordinator.setCanvas(geometry.size, scale: scale) }
        }.allowsHitTesting(false)
    }
}

struct AetherSubtitleOverlay: View {
    let backend: AetherMKVPlayback
    var controlsVisible = false
    var videoRect: CGRect? = nil
    @ObservedObject private var clock: PlaybackClock
    @ObservedObject private var engine: AetherEngine
    init(backend: AetherMKVPlayback, controlsVisible: Bool = false, videoRect: CGRect? = nil) {
        self.backend = backend; self.controlsVisible = controlsVisible; self.videoRect = videoRect
        _clock = ObservedObject(wrappedValue: backend.engine.clock)
        _engine = ObservedObject(wrappedValue: backend.engine)
    }
    var body: some View {
        if backend.usesSubtitleOverlay {
            if let coordinator = backend.styledSubtitles {
                StyledOrPlainSubtitles(backend: backend, coordinator: coordinator, controlsVisible: controlsVisible, time: clock.sourceTime, videoRect: videoRect)
            } else {
                AetherPlainSubtitles(engine: engine, videoSize: CGSize(width: Int(backend.info.width), height: Int(backend.info.height)), controlsVisible: controlsVisible, time: clock.sourceTime)
            }
        }
    }
}

private struct StyledOrPlainSubtitles: View {
    let backend: AetherMKVPlayback
    @ObservedObject var coordinator: StyledASSCoordinator
    let controlsVisible: Bool
    let time: Double
    let videoRect: CGRect?
    var body: some View {
        if coordinator.active {
            GeometryReader { geometry in
                let aspect = CGSize(width: max(1, Int(backend.info.width)), height: max(1, Int(backend.info.height)))
                let rect = videoRect ?? AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: geometry.size))
                StyledASSOverlay(coordinator: coordinator)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }.clipped()
        } else {
            AetherPlainSubtitles(engine: backend.engine, videoSize: CGSize(width: Int(backend.info.width), height: Int(backend.info.height)), controlsVisible: controlsVisible, time: time)
        }
    }
}

#if os(macOS)
final class SubtitleHostingView: NSHostingView<AetherSubtitleOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
#endif
