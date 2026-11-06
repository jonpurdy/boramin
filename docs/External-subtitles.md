# External subtitles

SMB and HTTP(S) playback discover `.srt`, `.vtt`, `.ass`, and `.ssa` files in the video's folder with the **exact video base filename**, optionally followed by a dot and a recognized language tag. Extensions and language tags are case-insensitive; the video base filename remains case-sensitive. For example, `Movie.mp4` matches `Movie.srt`, `Movie.ASS`, `Movie.en.srt`, `Movie.eng.srt`, `Movie.en-US.srt` and `Movie.zh-Hans-CN.srt`, but not `Another Movie.srt` or `Movie.commentary.srt`. Matching is independent of the browser's Display all files setting.

Tags use Foundation's known two-/three-letter language codes, optionally followed by a recognized four-letter script and/or two-letter or three-digit region, separated by hyphens. Unknown codes, malformed tags, underscore separators and qualifiers such as `.en.forced` / `.en.sdh` are not matched. SMB deletion uses the same matcher and preserves any subtitle also associated with another supported video, including overlapping names such as `Movie.en.mkv` sharing `Movie.en.srt` with `Movie.mkv`.

Matching tracks appear as **SRT — External**, **VTT — External**, etc.; language-tagged tracks include a localized language label, such as **English — SRT — External** or **Portuguese (Brazil) — SRT — External**. in **Audio & Subtitles**, alongside embedded subtitle options and Off. Discovery does not automatically enable subtitles. Selecting an external track loads only that subtitle file; the video is still streamed through its original playback route. The source files are unchanged.

## Rendering and selection

- The existing bundled FFmpeg text decoders read each selected sidecar and normalize its timed events to ASS. This preserves the markup supported by those decoders without an app-written SRT/VTT parser.
- The existing `ASSRasterizer` feeds those events and their style header to libass. ASS/SSA scripts retain authored styles/positioning/animation. SRT/VTT use FFmpeg's generated styles; this does not promise support for all WebVTT CSS, regions or cue-position settings.
- Following AetherPlayer's architecture, one app-written **Audio & Subtitles** panel lists source audio, embedded subtitles, external subtitles and Off. iOS presents a SwiftUI sheet with sections; macOS presents a SwiftUI popover. Native tvOS exposes a standard system menu above the scrubber. Software playback uses the same model and a sheet/popover or tvOS menu.
- Native AVPlayer playback uses its public content overlay. These external tracks are app-rendered options, not new AVFoundation media-selection options. AVKit can still expose its own embedded subtitle control; external tracks belong to the app's Audio & Subtitles panel.
- Native AetherEngine playback keeps its video/audio transport controls. The track panel uses its public source-selection APIs. On native audio-track reloads, iOS/tvOS/macOS refresh the current-item observers and track bindings, preserving completion/error handling.
- Selecting external subtitles disables embedded captions. Selecting an embedded track or Off clears the external bitmap and cancels any pending sidecar load. MP4 embedded selection through AVKit is also observed; programmatic Off transitions are allowed to settle before interpreting a native selection as a new choice.
- Existing embedded subtitle routing is retained: MKV ASS/SSA uses libass; other embedded tracks keep their native/plain-text/bitmap path. The AetherEngine Off action now calls its public `clearSubtitle()` API rather than selecting an invalid stream index.
- Embedded PGS bitmap tracks use the existing image-caption overlay even when AetherEngine supplies a native AVPlayer and the MKV has no ASS track or matching sidecar. Native caption rendering is disabled for the selected bitmap track so it does not depend on a text rendition/OCR. Native plain-text selection is retained, and overlay visibility follows track switches and Off.
- Subtitle rendering follows the native AVPlayer timeline or AetherEngine's source clock, including seeking and saved-position resume. Native AVPlayer callbacks run at up to 30 Hz; libass only publishes changed images.

## Bounds and lifecycle

Sidecars are limited to 8 MiB each, 50,000 decoded cues, 64 KiB per cue, and 16 MiB of decoded event text. Only the selected document is retained. Downloads use a bounded byte range and reject a file that changes size during loading. FFmpeg uses a forced text demuxer and file-only protocol on a private temporary file, removed immediately after decoding. No movie is downloaded or remuxed.

Loading/decoding/font setup is cancelled on a new selection or playback stop. Generation checks discard late results. The shared libass worker/cache limits and periodic cue-window rebuilding apply. Embedded fonts from an AetherEngine source can be used by its sidecars; standalone external font files are not discovered. Missing fonts fall back through CoreText.

Discovery errors do not block video playback. A selected track's load/decode error is logged with Apple's logger and shown over the video; other tracks, Off, and video playback remain available.

These overlays do not accompany video into Picture in Picture, AirPlay or external playback. Subtitle selection is remembered and synced only alongside an unfinished playback position, as described below. Language suffix matching, subtitle offsets, external bitmap subtitles and subtitle search/download are not included.

## Remembering subtitle selection

A selected embedded or external subtitle track is saved with the video's unfinished playback position, including when the video is reopened through Watching or Files. Selecting subtitles alone does not create a Watching entry. Explicit Off is remembered too, so an earlier track does not return unexpectedly.

External tracks use their exact subtitle filename; AetherEngine tracks use the source stream ID plus codec/language/name; native AVPlayer tracks use the public media-selection property list with an unambiguous metadata fallback. A missing saved track is left Off, preserving its identity for other devices until the user chooses another track or Off. Menu indexes are not used as portable identifiers.

The choice is an optional field in the existing encrypted iCloud position payload, so position and subtitle choice follow the same conflict-resolution timestamp and require no CloudKit schema change. Sync follows **Sync via iCloud**. Older position payloads without a subtitle choice remain valid. Completion, Reset Playback and bookmark eviction remove the choice locally and through the existing synced reset/position handling. Subtitle Size remains a separate device-local setting.

October 26 validation: isolated bookmark tests passed identity persistence, Off, cloud-field application/legacy compatibility, reset/completion cleanup and eviction. The playback probe passed external/native/MKV track restoration, actual external bitmap output after reopening, and missing-track safety. iOS, tvOS and macOS builds passed. This does not constitute a live cross-device iCloud sync test; the feature build was subsequently deployed to Apple TV, Mac, and test device.

## Subtitle size

**Settings** includes **Subtitle Size** for external text subtitles and embedded ASS/SSA: 100%, 125%, 150%, and 200%. The initial value is 125%; 100% restores the authored font scale. The choice is saved in local preferences per device and is not included in iCloud sync.

The shared libass renderer uses its public `ass_set_font_scale` API, applied on the same serial worker as rendering. Changes redraw the current subtitle even while playback is paused, without reopening the track or changing the video/audio pipeline. Both external subtitles and embedded ASS/SSA observe the preference. Fonts, colors, event timing and animation remain script-driven, but larger text can alter line wrapping or overlap authored layouts. Native AVKit captions and bitmap subtitles retain their existing appearance behavior.

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

## tvOS menu visibility correction

The initial unified transport menu supplied deferred elements and nested inline sections. AVKit’s SDK contract accepts concrete `UIMenu`/`UIAction` items and does not support nested menus. The tvOS implementation now supplies a flat menu of concrete actions, prefixes rows with Audio/Subtitles, and rebuilds only when audio rows/selection or subtitle rows/selection change. It also reapplies on player appearance and item replacement. Frame/clock updates do not rebuild menus. This preserves system controls and avoids private view inspection.

## Embedded PGS rendering correction (October 31)

The reported `ENG (pgssub)` track was visible in the menu but produced no captions. Native Aether playback without ASS/sidecars did not attach BoraMin's image overlay, and track selection requested native subtitle rendering for bitmap tracks. The correction attaches the existing overlay and routes supported bitmap selections to it; plain native captions retain their path, and engine selection changes control overlay visibility.

A synthetic PGS/SRT MKV reproduced the missing overlay pixels before the fix despite decoded PGS image cues and native video output. Afterward, the production caption-view pixel checks passed for selection, Off, reselection and seek, plus switching back to native SRT without replacing the player/item. The complete external subtitle probe, main suite, sequential offline browsing/cancellation probes, and all three platform Release builds passed. Generated diagnostic apps were removed; before/after and validation logs are under ignored `build/PGSSubtitles/`. The corrected development-signed 0.5 (5) Release build was subsequently installed on the paired Apple TV at the user's request; `build/PGSSubtitles/tvos-install.json` records success. The user confirmed that the embedded PGS subtitles now work on Apple TV after deployment. No upload was performed.
