# AetherEngine dependency

Source: https://github.com/superuser404notfound/AetherEngine
Pinned revision: 814fef14d394c13c378869dc5c13963af8be9a0d
License: LGPL v3 with upstream Apple Store / DRM exception, retained in LICENSE and bundled as AetherEngine-LICENSE.txt.

Only Sources/AetherEngine and its package target are included. BoraMin supplies SMB through IOReader; upstream SMB, command-line, examples and test targets are omitted. Optional package traits remain disabled. Dependencies are resolved by SwiftPM and pinned in the application's Package.resolved.

Local compiler compatibility changes for Xcode 26.3 / Swift 6.2:
- StereoVideoSignal.viewPackingBox explicitly converts its bitwise flag expression to UInt8.
- AetherEngine.loadSession's forcesSoftware closure explicitly retains MainActor isolation, matching the engine and VTCapabilityProbe it calls.

No playback algorithm changes. BoraMin's adapter is Player/AetherMKVPlayback.swift. Existing C/FFmpeg code is linked inside BoraMinMedia.framework, exporting only media_*; this prevents its static FFmpeg symbols from overriding the engine's dynamic frameworks.

This is an opt-in native H.264/HEVC MKV experiment (--aether-mkv). VP9 and ordinary app launches retain their existing routing. See docs/AetherEngine-integration.md for validation and limitations.
