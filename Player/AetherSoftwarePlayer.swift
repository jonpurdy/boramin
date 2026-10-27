#if canImport(AetherEngine)
import SwiftUI
import AetherEngine
import OSLog

private let softwareLog = Logger(subsystem: "com.example.BoraMin", category: "SoftwarePlayback")

/// Uses only AetherEngine's public surface/transport API and standard SwiftUI controls.
/// AetherPlayer's separate surface + transport design is the reference; no UI source is copied.
@MainActor final class AetherSoftwareModel: ObservableObject {
    let media: PreparedMedia
    let backend: AetherMKVPlayback
    private let positions: PlaybackPositions
    @Published var position = 0.0
    @Published var debugText = ""
    private var started = false
    private var stopped = false
    private var completed = false
    private var restored = false
    private var lastCheckpoint = 0.0
    private var lastBytes: Int64 = 0
    private var lastSample = ProcessInfo.processInfo.systemUptime
    private let stats = PlaybackDebugStats()
    private var seekTask: Task<Void, Never>?
    var engine: AetherEngine { backend.engine }
    var decoderLabel: String {
        let decoder = engine.activeVideoDecoder ?? ""
        if decoder.contains("(HW)") { return "Hardware Decoding" }
        if decoder.contains("(SW)") { return "Software Decoding" }
        return "System Decoding (HW/SW unknown)"
    }
    var duration: Double { engine.duration.isFinite && engine.duration > 0 ? engine.duration : max(0, media.info.duration) }
    init(media: PreparedMedia, backend: AetherMKVPlayback, positions: PlaybackPositions? = nil) {
        self.media = media; self.backend = backend; self.positions = positions ?? .shared
    }
    func start() async {
        guard !started, !stopped else { return }
        started = true
        softwareLog.notice("Software playback opened session=\(self.media.id.uuidString, privacy: .public) title=\(self.media.title, privacy: .private)")
        if engine.currentTime < 0.25, !CommandLine.arguments.contains("--no-playback-history"), let key = media.positionKey,
           let saved = positions.position(for: key, duration: duration) {
            await engine.seek(to: saved)
        }
        guard !Task.isCancelled, !stopped else { return }
        restored = true
        lastBytes = media.streaming?.source.fetchedBytes ?? 0
        lastSample = ProcessInfo.processInfo.systemUptime
        engine.play()
    }
    func seek(to value: Double) {
        guard !stopped, value.isFinite, duration > 0 else { return }
        let target = min(max(0, value), max(0, duration - 0.1))
        seekTask?.cancel()
        seekTask = Task { await engine.seek(to: target) }
    }
    func tick(debug: Bool) {
        guard !stopped else { return }
        let time = engine.currentTime
        if time.isFinite { position = max(0, time) }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCheckpoint >= 5 { save(); lastCheckpoint = now }
        guard debug, now - lastSample >= 1 else { return }
        let metrics = media.streaming?.source.transferMetrics
        let speed = metrics.map { Double(max(0, $0.fetched - lastBytes)) / max(0.001, now - lastSample) / 1_000_000 } ?? 0
        lastBytes = metrics?.fetched ?? 0; lastSample = now
        debugText = ([String(format: "Network: %.2f MB/s", speed),
                     metrics.map { String(format: "Cache: %.1f / %.0f MiB", Double($0.cached) / 1048576, Double($0.capacity) / 1048576) } ?? "Cache: unavailable",
                     String(format: "Video: %d × %d, %.2f fps", media.info.width, media.info.height, media.info.frame_rate),
                     "Decoder: \(engine.activeVideoDecoder ?? decoderLabel)"]
             + stats.lines(item: nil, video: nil)).joined(separator: "\n")
    }
    func finish() {
        guard !stopped, !completed else { return }
        completed = true
        if !CommandLine.arguments.contains("--no-playback-history"), let key = media.positionKey { positions.clear(key) }
    }
    private func save() {
        guard restored, !stopped, !completed, !CommandLine.arguments.contains("--no-playback-history"),
              let key = media.positionKey else { return }
        positions.save(engine.currentTime, duration: duration, for: key, subtitle: media.subtitleSelection)
    }
    func stop() {
        guard !stopped else { return }
        save(); stopped = true; seekTask?.cancel()
        softwareLog.notice("Software playback closing session=\(self.media.id.uuidString, privacy: .public) position=\(self.position) completed=\(self.completed)")
        media.streaming?.stop(); backend.stop()
        NotificationCenter.default.post(name: Notification.Name("BoraMinPlaybackSync"), object: nil)
    }
}

@MainActor struct AetherSoftwarePlayer: View {
    @StateObject private var model: AetherSoftwareModel
    @StateObject private var tracks: PlaybackTracks
    @State private var tracksPresented = false
    @ObservedObject private var engine: AetherEngine
    @AppStorage("showDebugInfo") private var showDebug = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    private enum PlaybackFocus: Hashable { case surface, playPause }
    @FocusState private var playbackFocus: PlaybackFocus?
    #endif
    @State private var controlsVisible = true
    @State private var lastInteraction = Date()
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    private let close: () -> Void
    private let failure: (String) -> Void
    init(media: PreparedMedia, backend: AetherMKVPlayback, close: @escaping () -> Void, failure: @escaping (String) -> Void) {
        self.init(model: AetherSoftwareModel(media: media, backend: backend), close: close, failure: failure)
    }
    init(model: AetherSoftwareModel, close: @escaping () -> Void, failure: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: model)
        _tracks = StateObject(wrappedValue: PlaybackTracks(media: model.media))
        _engine = ObservedObject(wrappedValue: model.engine)
        self.close = close; self.failure = failure
    }
    var body: some View {
        ZStack {
            Color.black
            AetherPlayerSurface(engine: engine)
                #if os(tvOS)
                // Focus belongs to the transport or the nonvisual focus target, never the engine view.
                .allowsHitTesting(false)
                #else
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible.toggle(); lastInteraction = Date() }
                #endif
            PlaybackSubtitleOverlay(media: model.media, controlsVisible: controlsVisible)
                .allowsHitTesting(false)
            if showDebug {
                Text(model.debugText).font(.system(.caption2, design: .monospaced))
                    .padding(10).background(.black.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(24)
                    .allowsHitTesting(false)
            }
            if engine.state == .loading || engine.state == .seeking { ProgressView().allowsHitTesting(false) }
            #if os(tvOS)
            if !controlsVisible {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .focusable()
                    .focusEffectDisabled()
                    .accessibilityLabel("Show playback controls")
                    .focused($playbackFocus, equals: .surface)
                    .onTapGesture { activity() }
                    .onMoveCommand { _ in activity() }
            }
            #endif
            if controlsVisible {
                VStack {
                    HStack {
                        Button("Close", systemImage: "xmark") { model.stop(); close() }
                        Text(model.media.title).lineLimit(1)
                        Spacer()
                        PlaybackTracksButton(tracks: tracks) { presented in
                            tracksPresented = presented; activity()
                        }
                    }
                    Spacer()
                    transport
                }
                .padding(30)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .task {
            tracks.bind(player: model.backend.player)
            await model.start()
            while !Task.isCancelled {
                model.tick(debug: showDebug)
                if !scrubbing, !tracksPresented, engine.state == .playing, Date().timeIntervalSince(lastInteraction) > 5 { controlsVisible = false }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .onChange(of: engine.state, initial: true) { _, state in
            switch state {
            case .ended: model.finish(); model.stop(); close()
            case .error(let message):
                softwareLog.error("Software playback failed: \(message, privacy: .private)")
                model.stop(); failure(message)
            case .paused: activity()
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop(); close() }
        }
        .onDisappear { tracks.stop(); model.stop() }
        #if os(tvOS)
        .onAppear { playbackFocus = .playPause }
        .onChange(of: controlsVisible) { _, visible in
            playbackFocus = visible ? .playPause : .surface
        }
        .onPlayPauseCommand { engine.togglePlayPause(); activity() }
        .onExitCommand {
            if controlsVisible { controlsVisible = false } else { model.stop(); close() }
        }
        #endif
    }
    private var transport: some View {
        VStack(spacing: 14) {
            HStack {
                Text(timecode(scrubbing ? scrubPosition : model.position))
                #if os(tvOS)
                ProgressView(value: min(model.position, model.duration), total: max(1, model.duration))
                    .focusable()
                    .accessibilityLabel("Playback position")
                    .accessibilityHint("Press left or right to seek ten seconds")
                    .onMoveCommand { direction in
                        activity()
                        if direction == .left { model.seek(to: model.position - 10) }
                        if direction == .right { model.seek(to: model.position + 10) }
                    }
                #else
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position, model.duration) }, set: { scrubPosition = $0; activity() }), in: 0...max(1, model.duration), onEditingChanged: { editing in
                    if editing { scrubPosition = model.position }
                    scrubbing = editing; activity()
                    if !editing { model.seek(to: scrubPosition) }
                })
                #endif
                Text(timecode(model.duration))
            }.monospacedDigit().font(.caption)
            HStack(spacing: 35) {
                Button("Back 10 seconds", systemImage: "gobackward.10") { model.seek(to: model.position - 10); activity() }
                Button(engine.state == .playing ? "Pause" : "Play", systemImage: engine.state == .playing ? "pause.fill" : "play.fill") { engine.togglePlayPause(); activity() }
                    #if os(tvOS)
                    .focused($playbackFocus, equals: .playPause)
                    #endif
                Button("Forward 10 seconds", systemImage: "goforward.10") { model.seek(to: model.position + 10); activity() }
            }.labelStyle(.iconOnly).font(.title2)
        }
    }
    private func activity() { lastInteraction = Date(); controlsVisible = true }
    private func timecode(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, Double(Int.max / 4)))) : 0
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

struct AetherPlainSubtitles: View {
    @ObservedObject var engine: AetherEngine
    let videoSize: CGSize
    let controlsVisible: Bool
    let time: Double
    var body: some View {
        GeometryReader { geometry in
            let ratio = videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let height = width / ratio
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            let cues = engine.subtitleCues.filter { time >= $0.startTime && time < $0.endTime }
            ZStack(alignment: .bottom) {
                ForEach(cues) { cue in
                    if case .image(let bitmap) = cue.body {
                        Image(decorative: bitmap.cgImage, scale: 1)
                            .resizable()
                            .frame(width: bitmap.position.width * width, height: bitmap.position.height * height)
                            .position(x: origin.x + bitmap.position.midX * width, y: origin.y + bitmap.position.midY * height)
                    }
                }
                VStack {
                    Spacer()
                    ForEach(cues) { cue in
                        if let text = cue.text {
                            Text(text).font(.title3).multilineTextAlignment(.center)
                                .padding(6).background(.black.opacity(0.65))
                        }
                    }
                }.padding(.horizontal, 30).padding(.bottom, controlsVisible ? 160 : 35)
            }
        }
    }
}
#endif

#if canImport(AetherEngine) && (os(tvOS) || os(iOS))
@MainActor struct AetherPlaybackPresentation: View {
    let media: PreparedMedia
    let backend: AetherMKVPlayback
    let close: () -> Void
    let failure: (String) -> Void
    @ObservedObject private var engine: AetherEngine
    init(media: PreparedMedia, backend: AetherMKVPlayback, close: @escaping () -> Void, failure: @escaping (String) -> Void) {
        self.media = media; self.backend = backend; self.close = close; self.failure = failure
        _engine = ObservedObject(wrappedValue: backend.engine)
    }
    var body: some View {
        if engine.videoRoute == .software || engine.videoRoute == .audio {
            AetherSoftwarePresentation(media: media, backend: backend, close: close, failure: failure)
        } else if engine.videoRoute == .none {
            Color.black
        } else {
            NativeAVPlayer(media: media) { message in
                // The engine may recover an AVPlayer decoder failure by switching routes.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, engine.state != .idle,
                          media.streaming?.source.cancellation.cancelled != true,
                          engine.videoRoute != .software, engine.videoRoute != .audio else { return }
                    failure(message)
                }
            }
        }
    }
}

@MainActor struct AetherSoftwarePresentation: UIViewControllerRepresentable {
    let media: PreparedMedia
    let backend: AetherMKVPlayback
    let close: () -> Void
    let failure: (String) -> Void
    func makeUIViewController(context: Context) -> AetherSoftwareHostingController {
        AetherSoftwareHostingController(media: media, backend: backend, close: close, failure: failure)
    }
    func updateUIViewController(_ controller: AetherSoftwareHostingController, context: Context) { }
    static func dismantleUIViewController(_ controller: AetherSoftwareHostingController, coordinator: ()) { controller.stop() }
}

@MainActor final class AetherSoftwareHostingController: UIHostingController<AetherSoftwarePlayer> {
    private let model: AetherSoftwareModel
    #if os(iOS)
    private let orientationID = UUID()
    private weak var playbackScene: UIWindowScene?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { true }
    #endif
    init(media: PreparedMedia, backend: AetherMKVPlayback, close: @escaping () -> Void, failure: @escaping (String) -> Void) {
        let model = AetherSoftwareModel(media: media, backend: backend)
        self.model = model
        super.init(rootView: AetherSoftwarePlayer(model: model, close: close, failure: failure))
        #if os(iOS)
        PlaybackOrientation.players.insert(orientationID)
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if os(iOS)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene ?? presentingViewController?.view.window?.windowScene {
            playbackScene = scene
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        #endif
    }
    func stop() {
        model.stop()
        #if os(iOS)
        PlaybackOrientation.players.remove(orientationID)
        if PlaybackOrientation.players.isEmpty, let scene = playbackScene {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let mask: UIInterfaceOrientationMask = UIDevice.current.orientation.isLandscape ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        #endif
    }
}
#endif
