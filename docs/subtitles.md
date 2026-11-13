# Subtitles

## External track matching

SMB and HTTP(S) playback discover `.srt`, `.vtt`, `.ass`, and `.ssa` files in the video's folder with the **exact video base filename**, optionally followed by a dot and a recognized language tag. Extensions and language tags are case-insensitive; the video base filename remains case-sensitive. For example, `Movie.mp4` matches `Movie.srt`, `Movie.ASS`, `Movie.en.srt`, `Movie.eng.srt`, `Movie.en-US.srt` and `Movie.zh-Hans-CN.srt`, but not `Another Movie.srt` or `Movie.commentary.srt`. Matching is independent of the browser's Display all files setting.

Tags use Foundation's known two-/three-letter language codes, optionally followed by a recognized four-letter script and/or two-letter or three-digit region, separated by hyphens. Unknown codes, malformed tags, underscore separators and qualifiers such as `.en.forced` / `.en.sdh` are not matched. SMB deletion uses the same matcher and preserves any subtitle also associated with another supported video, including overlapping names such as `Movie.en.mkv` sharing `Movie.en.srt` with `Movie.mkv`.

Matching tracks appear as **SRT — External**, **VTT — External**, etc.; language-tagged tracks include a localized language label, such as **English — SRT — External** or **Portuguese (Brazil) — SRT — External** in **Subtitles**, alongside embedded subtitle options and Off. Discovery does not automatically enable subtitles. Selecting an external track loads only that subtitle file; the video is still streamed through its original playback route. The source files are unchanged.

## Rendering and selection

- The existing bundled FFmpeg text decoders read each selected sidecar and normalize its timed events to ASS. This preserves the markup supported by those decoders without an app-written SRT/VTT parser.
- The existing `ASSRasterizer` feeds those events and their style header to libass. ASS/SSA scripts retain authored styles/positioning/animation. SRT/VTT use FFmpeg's generated styles; this does not promise support for all WebVTT CSS, regions or cue-position settings.
- Separate Audio and Subtitles controls use the same track model. iOS opens a sheet, macOS opens a popover, and tvOS opens a menu. The Subtitles control lists embedded tracks, external tracks, and Off.
- Native AVPlayer playback uses its public content overlay. These external tracks are app-rendered options, not new AVFoundation media-selection options. AVKit handles native-only subtitles. When BoraMin offers app-managed subtitle choices on tvOS, it filters AVKit’s built-in subtitle options and presents the choices in BoraMin’s Subtitles menu. On iOS, BoraMin places supplemental track controls above the native transport and shows them when the app has track choices to offer.
- Native AetherEngine playback keeps its video/audio transport controls. The track panel uses its public source-selection APIs. On native audio-track reloads, iOS/tvOS/macOS refresh the current-item observers and track bindings, preserving completion/error handling.
- Selecting external subtitles disables embedded captions. Selecting an embedded track or Off clears the external bitmap and cancels any pending sidecar load. MP4 embedded selection through AVKit is also observed; programmatic Off transitions are allowed to settle before interpreting a native selection as a new choice.
- Existing embedded subtitle routing is retained: MKV ASS/SSA uses libass; other embedded tracks keep their native/plain-text/bitmap path. The AetherEngine Off action now calls its public `clearSubtitle()` API rather than selecting an invalid stream index.
- Embedded PGS bitmap tracks use the existing image-caption overlay even when AetherEngine supplies a native AVPlayer and the MKV has no ASS track or matching sidecar. Native caption rendering is disabled for the selected bitmap track so it does not depend on a text rendition/OCR. Native plain-text selection is retained, and overlay visibility follows track switches and Off.
- Subtitle rendering follows the native AVPlayer timeline or AetherEngine's source clock, including seeking and saved-position resume. Native AVPlayer callbacks run at up to 30 Hz; libass only publishes changed images.

### Embedded ASS/SSA

MKV uses AetherEngine automatically except VP9. VP9 MKV now uses BoraMin's original hardware decoder and native AVKit controls; it retains external subtitle support but does not expose AetherEngine's embedded subtitle/audio selections. Other MKVs use the engine's native AVPlayer where supported and its software fallback otherwise.

The engine probes embedded tracks before loading. Only an MKV with at least one ASS/SSA track enables raw ASS markup and the libass coordinator. For these files the engine's plain native subtitle renditions are disabled to prevent duplicate/unformatted ASS captions.

Selecting ASS/SSA activates libass; other source subtitle tracks use the existing plain-text/bitmap overlay. Selecting Off clears the overlay. Files without ASS retain their existing native subtitle preparation. Subtitles are initially off unless the engine selects a track; the presence of ASS does not force it on.

AetherEngine supplies the original header, raw timed events, embedded font data and picture-aligned source clock. The app feeds events to libass's public `ass_process_codec_private` / `ass_process_chunk` APIs. It uses the existing SwiftAssRenderer bitmap blending pipeline to draw libass output in the video rectangle through public SwiftUI/AVKit overlay APIs. No video burn-in or re-encoding occurs. No internal AVKit views are inspected.

BoraMin manages libass tracks directly on one serial worker queue, incrementally appending and deduplicating events. This avoids script reload flashes and explicitly frees track, renderer and library pointers.

- Full ASS/SSA markup is preserved, including position, colors, transformations and animation.
- MKV font attachments are passed directly to `ass_add_font`, before initializing CoreText font selection; no global font registration or extraction into user folders is needed. Missing fonts can still fall back.
- Font setup runs off the main actor and is cancelled when switching tracks or closing.
- Rendering follows AetherEngine's source clock, including pause/resume and seek landing.
- At most one bitmap render/publication is in flight. Events are processed only when the cue window changes or needs rebuilding.
- Event storage is periodically flushed/rebuilt from the engine's current subtitle window; seeks also rebuild it. Libass bitmap cache is limited to 32 MiB. This is additional to the existing compressed SMB cache and other player memory.
- Render callbacks are scoped to the selected track generation so a closed/switched track cannot redraw stale subtitles.

### Renderer dependencies

SwiftAssRenderer 1.3.1 / SwiftLibass 1.4.0 are pinned through SwiftPM. The binaries report libass 0.17.3, FriBidi 1.0.14 and HarfBuzz 8.5.0. Other component versions/notices are recorded under `vendor/Subtitle-notices` and `vendor/DEPENDENCIES.md`. No AetherEngine dependency patches were needed.

## Bounds and lifecycle

Sidecars are limited to 8 MiB each, 50,000 decoded cues, 64 KiB per cue, and 16 MiB of decoded event text. Only the selected document is retained. Downloads use a bounded byte range and reject a file that changes size during loading. FFmpeg uses a forced text demuxer and file-only protocol on a private temporary file, removed immediately after decoding. No movie is downloaded or remuxed.

Loading/decoding/font setup is cancelled on a new selection or playback stop. Generation checks discard late results. The shared libass worker/cache limits and periodic cue-window rebuilding apply. Embedded fonts from an AetherEngine source can be used by its sidecars; standalone external font files are not discovered. Missing fonts fall back through CoreText.

Discovery errors do not block video playback. A selected track's load/decode error is logged with Apple's logger and shown over the video; other tracks, Off, and video playback remain available.

These overlays do not accompany video into Picture in Picture, AirPlay or external playback. Subtitle selection is remembered and synced only alongside an unfinished playback position, as described below. Subtitle offsets, external bitmap subtitles and subtitle search/download are not included.

## Remembering subtitle selection

A selected embedded or external subtitle track is saved with the video's unfinished playback position, including when the video is reopened through Watching or Files. Selecting subtitles alone does not create a Watching entry. Explicit Off is remembered too, so an earlier track does not return unexpectedly.

External tracks use their exact subtitle filename; AetherEngine tracks use the source stream ID plus codec/language/name; native AVPlayer tracks use the public media-selection property list with an unambiguous metadata fallback. A missing saved track is left Off, preserving its identity for other devices until the user chooses another track or Off. Menu indexes are not used as portable identifiers.

The choice is an optional field in the existing encrypted iCloud position payload, so position and subtitle choice follow the same conflict-resolution timestamp and require no CloudKit schema change. Sync follows **Sync via iCloud**. Older position payloads without a subtitle choice remain valid. Completion, Reset Playback and bookmark eviction remove the choice locally and through the existing synced reset/position handling. Subtitle Size remains a separate device-local setting.

October 26 validation: isolated bookmark tests passed identity persistence, Off, cloud-field application/legacy compatibility, reset/completion cleanup and eviction. The playback probe passed external/native/MKV track restoration, actual external bitmap output after reopening, and missing-track safety. iOS, tvOS and macOS builds passed. This does not constitute a live cross-device iCloud sync test; the feature build was subsequently deployed to Apple TV, Mac, and test device.

## Subtitle size

**Settings** includes **Subtitle Size** for external text subtitles and embedded ASS/SSA: 100%, 125%, 150%, and 200%. The initial value is 125%; 100% restores the authored font scale. The choice is saved in local preferences per device and is not included in iCloud sync.

The shared libass renderer applies the size multiplier with `ass_set_font_scale()` on its serial rendering queue. Changes redraw the current subtitle even while playback is paused. Native AVKit captions and bitmap subtitles retain their existing appearance behavior.

### Positioned ASS text and drawings

libass enables `ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE` by default. It uses tags such as `\pos`, `\move`, and `\p` to identify events that its dialogue-only scaling heuristic skips. This caused some ASS captions to stay at their authored size even at 200%.

**Subtitles: scale all text** is on by default. It clears that flag so the size multiplier also applies to positioned text and vector drawings. Turning it off restores libass’s selective scaling. Fonts, colors, timing, and animation remain script-driven. Larger subtitles can wrap differently, overlap authored elements, or be cropped by script clips or the video edges.

The [local regression probe](#local-regression-probe) checks that positioned ASS grows at 200% while paused, that toggling the setting at 200% updates the current frame, and that returning to 100% restores the original bounds and pixels. The main test suite checks bitmap output for the live ASS fixture.

## Local regression probe

Generate the existing ASS fixture, then an MP4 containing its plain embedded track:

```sh
python3 tools/create_ass_fixture.py
python3 tools/create_pgs_fixture.py
ffmpeg -v error -y -i build/ASSTests/styled.mkv -map 0:v -map 0:a -map 0:s:1 -c:v copy -c:a copy -c:s mov_text build/ASSTests/external-fixture.mp4
python3 tools/run_playback_probe.py --generate-only external
xcodebuild -project build/AetherSoftwareTests/Probe.xcodeproj -scheme 'BoraMin macOS' -configuration Release -destination 'platform=macOS,arch=arm64' -clonedSourcePackagesDirPath build/AetherPackages -derivedDataPath build/AetherSoftwareTests/Derived build
build/AetherSoftwareTests/Derived/Build/Products/Release/BoraMin.app/Contents/MacOS/BoraMin "$PWD/build/ASSTests"
```

The default probe uses generated local fixtures, not real server credentials or user history. It checks all four decoders, timestamps, bitmap output, ASS colors/positioning, forward/backward seek pixel changes, native MP4 embedded/external switching, unified-panel audio rows/selection, AVKit selection, AetherEngine embedded/external ASS switching, Off, cancellation and teardown. Its PGS MKV uses production source preparation with no ASS or sidecar: the probe confirms native video output and decoded PGS image cues, then counts actual rendered pixels from the production SwiftUI caption overlay. It checks Off, reselection, seek and a switch back to native SRT captions while retaining the original AVPlayer/item. An optional real-SMB mode takes additional arguments: workspace directory (to read ignored defaults without logging/bundling them), share name, and video path.

Passed on macOS on October 25, 2026. The iOS, tvOS and macOS app builds and private FFmpeg linkage checks also passed. The initial unified panel build was installed on Apple TV and Mac; the subsequent subtitle feature build was also deployed to test device. GUI validation is being handled by the user.

The actual external ASS fixture MP4/ASS pair also passed SMB discovery, bounded download, libass bitmap rendering, production playback preparation, and installation of the Mac subtitle overlay/menu host. The earlier GUI report was resolved by using the app's top-right subtitle control rather than AVKit's embedded-track menu. The subsequent unified panel replaces that standalone picker.

### Embedded ASS regression probe

`tools/create_ass_fixture.py` generates a local H.264/AAC MKV with colored/positioned/animated ASS, an SRT track and an attached test font. The system font is used only for this generated local fixture; it is not bundled in BoraMin.

`Tests/StyledASSPlaybackProbe.swift` builds in the isolated Mac probe target using `python3 tools/run_playback_probe.py --generate-only ass`. It verifies actual native decoded video pixels, a non-empty libass bitmap, red/green text, authored position, changing animation frames, forward/backward seeks, pause, ASS/SRT/Off switching, font delivery and teardown. The original AVPlayer is retained throughout. Generated logs and the rendered bitmap stay under ignored `build/` paths.

## tvOS menu visibility correction

The initial unified transport menu supplied deferred elements and nested inline sections. AVKit’s SDK contract accepts concrete `UIMenu`/`UIAction` items and does not support nested menus. The tvOS implementation now supplies a flat menu of concrete actions, prefixes rows with Audio/Subtitles, and rebuilds only when audio rows/selection or subtitle rows/selection change. It also reapplies on player appearance and item replacement. Frame/clock updates do not rebuild menus. This preserves system controls and avoids private view inspection.

## Embedded PGS rendering correction (October 31)

The reported `ENG (pgssub)` track was visible in the menu but produced no captions. Native Aether playback without ASS/sidecars did not attach BoraMin's image overlay, and track selection requested native subtitle rendering for bitmap tracks. The correction attaches the existing overlay and routes supported bitmap selections to it; plain native captions retain their path, and engine selection changes control overlay visibility.

A synthetic PGS/SRT MKV reproduced the missing overlay pixels before the fix despite decoded PGS image cues and native video output. Afterward, the production caption-view pixel checks passed for selection, Off, reselection and seek, plus switching back to native SRT without replacing the player/item. The complete external subtitle probe, main suite, sequential offline browsing/cancellation probes, and all three platform Release builds passed. Generated diagnostic apps were removed; before/after and validation logs are under ignored `build/PGSSubtitles/`. The corrected development-signed 0.5 (5) Release build was subsequently installed on the paired Apple TV at the user's request; `build/PGSSubtitles/tvos-install.json` records success. The user confirmed that the embedded PGS subtitles now work on Apple TV after deployment. No upload was performed.
