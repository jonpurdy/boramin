# Styled ASS/SSA subtitles

Implemented October 25, 2026. The proposed libVLC integration was cancelled and removed before any build was deployed. No VLC framework is linked.

Matching external SRT/VTT/ASS/SSA files are now supported through the shared renderer; see [external subtitles](External-subtitles.md). The embedded-track behavior below applies to AetherEngine sessions.

## Playback and selection

MKV uses AetherEngine automatically except VP9. VP9 MKV now uses BoraMin's original hardware decoder and native AVKit controls; it retains external subtitle support but does not expose AetherEngine's embedded subtitle/audio selections. Other MKVs use the engine's native AVPlayer where supported and its software fallback otherwise.

The engine probes embedded tracks before loading. Only an MKV with at least one ASS/SSA track enables raw ASS markup and the libass coordinator. For these files the engine's plain native subtitle renditions are disabled to prevent duplicate/unformatted ASS captions. The source subtitle picker exposes Off and all embedded subtitle tracks:

- tvOS native playback: the **Subtitles** system menu above the scrubber.
- iOS native playback: the **Subtitles** SwiftUI sheet, opened from the public video overlay.
- macOS native playback: the **Subtitles** popover in the video overlay.
- Software playback: the same track model and sheet/popover or tvOS menu.

Selecting ASS/SSA activates libass; other source subtitle tracks use the existing plain-text/bitmap overlay. Selecting Off clears the overlay. Files without ASS retain their existing native subtitle preparation. Subtitles are initially off unless the engine selects a track; the presence of ASS does not force it on.

## Rendering

AetherEngine supplies the original header, raw timed events, embedded font data and picture-aligned source clock. The app feeds events to libass's public `ass_process_codec_private` / `ass_process_chunk` APIs. It uses the existing SwiftAssRenderer bitmap blending pipeline to draw libass output in the video rectangle through public SwiftUI/AVKit overlay APIs. No video burn-in or re-encoding occurs. No internal AVKit views are inspected.

The reference is AetherPlayer's separation of native video, source subtitle events and libass overlay. Its high-level renderer repeatedly reloads accumulated scripts. BoraMin instead manages libass tracks directly on one serial worker queue, incrementally appending and deduplicating events. This avoids script reload flashes and explicitly frees track, renderer and library pointers.

- Full ASS/SSA markup is preserved, including position, colors, transformations and animation.
- MKV font attachments are passed directly to `ass_add_font`, before initializing CoreText font selection; no global font registration or extraction into user folders is needed. Missing fonts can still fall back.
- Font setup runs off the main actor and is cancelled when switching tracks or closing.
- Rendering follows AetherEngine's source clock, including pause/resume and seek landing.
- At most one bitmap render/publication is in flight. Events are processed only when the cue window changes or needs rebuilding.
- Event storage is periodically flushed/rebuilt from the engine's current subtitle window; seeks also rebuild it. Libass bitmap cache is limited to 32 MiB. This is additional to the existing compressed SMB cache and other player memory.
- Render callbacks are scoped to the selected track generation so a closed/switched track cannot redraw stale subtitles.

Styling is an in-app overlay. PiP/AirPlay/external playback cannot carry this overlay with the compressed video. This does not add styled subtitles to those remote surfaces. Malformed scripts or unavailable fonts can still differ from the author's intended output.

## Dependencies

SwiftAssRenderer 1.3.1 / SwiftLibass 1.4.0 are pinned through SwiftPM. The binaries report libass 0.17.3, FriBidi 1.0.14 and HarfBuzz 8.5.0. Other component versions/notices are recorded under `vendor/Subtitle-notices` and `vendor/DEPENDENCIES.md`. No AetherEngine dependency patches were needed.

## Validation

`tools/create_ass_fixture.py` generates a local H.264/AAC MKV with colored/positioned/animated ASS, an SRT track and an attached test font. The system font is used only for this generated local fixture; it is not bundled in BoraMin.

`Tests/StyledASSPlaybackProbe.swift` builds in the isolated Mac probe target using `python3 tools/run_playback_probe.py --generate-only ass`. It verifies actual native decoded video pixels, a non-empty libass bitmap, red/green text, authored position, changing animation frames, forward/backward seeks, pause, ASS/SRT/Off switching, font delivery and teardown. The original AVPlayer is retained throughout. Generated logs and the rendered bitmap stay under ignored `build/` paths.

The final execution passed all checks on macOS after the background font setup, incremental-event processing and canvas-scaling changes. iOS/tvOS/macOS app schemes built successfully, dependency-isolation checks passed, and all three bundles contain the new subtitle notices without a VLCKit framework. Real-file/device subtitle behavior and external playback still require validation; no new device installation is part of this change.
