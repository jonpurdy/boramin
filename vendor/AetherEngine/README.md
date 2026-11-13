# AetherEngine dependency

Source: https://github.com/superuser404notfound/AetherEngine
Pinned release: 7.56.0
Pinned revision: 76ad51a7a0a13d4844c48a90db98d6ca6abcb458
License: LGPL v3 with upstream Apple Store / DRM exception, retained in LICENSE and bundled as AetherEngine-LICENSE.txt.

Only Sources/AetherEngine and its package target are included. BoraMin supplies SMB through IOReader; upstream SMB, command-line, examples and test targets are omitted. Optional package traits remain disabled. Dependencies are resolved by SwiftPM and pinned in the application's Package.resolved.

Local compiler compatibility changes for Xcode 26.3 / Swift 6.2:
- StereoVideoSignal.viewPackingBox explicitly converts its bitwise flag expression to UInt8.
- AetherEngine.loadSession's forcesSoftware closure explicitly retains MainActor isolation, matching the engine and VTCapabilityProbe it calls.

Local playback correction: SoftwarePlaybackHost parks excess VOD audio as compressed packets instead of stopping all demuxing at the decoded-audio target. The queue is limited to 4 MiB / 2,048 packets (plus one indivisible packet), drains at the existing audio lead target, and is cleared on seek or teardown. Queued audio can drain while the video packet queue is full, and new audio packets join the back of the queue even if the clock crosses the audio lead threshold during a demux read. EOF waits for queued audio. Live playback retains upstream scheduling. The patch addresses the reproducible K-Pop startup stall and the packet reordering reproduced with an AVI/MP3 episode.

BoraMin's adapter is Player/AetherMKVPlayback.swift. Existing C/FFmpeg code is linked inside BoraMinMedia.framework, exporting only media_*; this prevents its static FFmpeg symbols from overriding the engine's dynamic frameworks.

Non-VP9 MKV and supported fallback containers use this engine automatically. Native sessions retain AVKit; alternate sessions use the public AetherPlayerSurface. See ../../docs/AetherEngine-playback.md for validation and limitations.
