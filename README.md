# BoraMin

A native SMB video player for Apple TV, iPhone/iPad, and Mac. Stream from your NAS, save favorite folders, and resume unfinished videos across devices using iCloud. No media is included; files come from an SMB server rather than local-file imports.

| Platform | Minimum OS | Xcode scheme |
| --- | --- | --- |
| Apple TV | tvOS 26.6 | BoraMin tvOS |
| iPhone / iPad | iOS 26.0 | BoraMin iOS |
| Apple Silicon Mac | macOS Sequoia 15.0 | BoraMin macOS |

All three targets live in **BoraMin.xcodeproj** and use `com.example.BoraMin`. Builds currently support physical arm64 devices, without simulator or Intel Mac slices.

## Features

- **Files:** browse SMB shares and folders, with automatic connection/reconnection to the saved server. Files and folders sort alphabetically together; dotfiles are hidden.
- **Favorites:** save folder/share paths using the context menu. Favorites sort alphabetically and keep their navigation separate from Files.
- **Watching:** unfinished videos, ordered by last save time. Filenames show progress such as `(80%, 00:12:45)`. Reopening resumes playback; completion returns to the previous screen. **Reset Playback** clears progress and the saved subtitle choice.
- **Audio & Subtitles:** select audio, embedded subtitles, external subtitles, or Off. Uses a sheet on iOS, a popover on Mac, and a system menu above the tvOS scrubber.
- **External subtitles:** load matching `.srt`, `.vtt`, `.ass`, or `.ssa` files from the video's folder. For example, `Movie.mp4` matches `Movie.ass`. ASS/SSA styling is rendered with libass.
- **Settings:** connection setup, iCloud sync, Display all files, Subtitle Size, and Show Debug Info. Subtitle Size offers 100%, 125%, 150%, and 200%, initially 125%, and is saved per device.
- **File deletion:** delete individual files through the context menu with confirmation. Folders cannot be deleted.

On first use, enter the server address and credentials under **Connection Setup**. Leave Share empty to browse available shares. Passwords are stored in Keychain; server addresses and credentials are never bundled with the app.

## Playback

- **MP4 / M4V / MOV:** native AVPlayer playback through the SMB resource loader, except VP9 files using the separate decoder path below.
- **Other MKVs and AetherEngine formats:** AetherEngine uses native AVPlayer when supported, otherwise its software video surface with app-written controls built from standard SwiftUI components.
- **VP9 in MKV / MP4 / M4V / MOV / WebM:** the original hardware VideoToolbox decoder and separate video layer, with AVKit controls. This path supports matching external subtitles, but not AetherEngine's embedded audio/subtitle track selection.

Playback streams requested ranges rather than downloading the whole movie. Each SMB stream has a **128 MiB compressed cache**; decoded frames and player buffers use additional memory.

Native sessions retain AVKit's transport controls. iOS playback opens in landscape and native video supports fit/fill pinch zoom. Mac uses native tables, windows, keyboard shortcuts, and full-screen playback.

### Subtitle behavior and limits

External text subtitles and embedded MKV ASS/SSA use the libass overlay; other embedded subtitles retain their native or existing overlay path. Subtitle Size affects libass text, while native captions use system appearance settings.

Selected subtitles, including explicit Off, are remembered only with an unfinished playback position and sync with that position. Completion and Reset Playback clear both. Missing saved tracks stay Off rather than selecting another subtitle.

External subtitles require an identical base filename; language suffixes such as `Movie.en.srt` are not matched. App-rendered subtitles do not follow video into PiP or AirPlay. Font fallback and SRT/VTT conversion can limit fidelity. See [subtitle support and limitations](docs/External-subtitles.md).

Codec/profile support depends on the engine, OS, and device. A recognized extension does not guarantee playback. Software playback and the separate VP9 layer do not inherit every native gesture or thumbnail-seeking feature. See [AetherEngine software playback](docs/AetherEngine-playback.md) and [VP9 investigation](Tests/Native-VP9-investigation.md).

## iCloud

**Sync via iCloud** synchronizes connection profiles, encrypted passwords, favorites, playback positions and subtitle choices, Watching metadata, and supported preferences through the user's private database. Settings provides sync status and **Sync Now**. Offline changes are queued; delivery is asynchronous. Subtitle Size and navigation state remain local.

Xcode development builds use CloudKit **Development**; TestFlight/App Store builds use **Production**. Those cloud datasets are separate, and switching builds does not migrate them or isolate existing local sync metadata. See [iCloud design and caveats](docs/iCloud-sync.md).

## Build

Requires Xcode, Python 3, make, and network access for initial dependency downloads. Dependencies include AMSMB2/libsmb2, FFmpeg, AetherEngine, and libass. Preserve the [dependency notices](vendor/DEPENDENCIES.md) when distributing.

Generate the project and build the FFmpeg libraries for the platforms you need:

```sh
python3 tools/create_project.py
python3 tools/build_ffmpeg.py --platform tvos
python3 tools/build_ffmpeg.py --platform ios
python3 tools/build_ffmpeg.py --platform macos
```

FFmpeg libraries only need rebuilding when missing or when their configuration changes. Open **BoraMin.xcodeproj**, select a scheme from the table above, choose your signing team, and build for a physical device or Apple Silicon Mac. SwiftPM resolves the engine/subtitle dependencies. Keep project-definition changes in `tools/create_project.py`; regeneration preserves version/build and signing choices.

The installed Xcode 26.3 supplies SDK 26.2, so the requested tvOS 26.6 target currently produces an SDK/deployment-target warning.

For beta archives, uploads, iCloud distribution setup, and release status, follow **[testflight.md](testflight.md)**.

## Development notes

- [Feature and bug-fix history](docs/Feature-history.md)
- [Playback logs and crash reports](docs/Diagnostics.md)
- [Subtitle regression fixtures and checks](docs/External-subtitles.md#local-regression-probe)
- [Device probes and investigations](Tests/README.md)
- [Streaming remux research and limits](Tests/Streaming-remux-investigation.md)

`Player/` contains shared browsing/playback code and iOS/tvOS views; `Shared/` contains iCloud sync; `iOS/` and `MacOS/` contain platform interfaces/configuration. `tools/`, `Tests/`, and `docs/` hold build helpers, probes, and investigation records.

`build/` and local `default_*.txt` files are ignored. Default files are not read by the apps or project generator. Preserve release archives and dSYMs needed for uploads and crash symbolication before cleaning generated products.
