# BoraMin

A native SMB and HTTP(S) video player for Apple TV, iPhone/iPad, and Mac. Stream from your NAS, save favorite folders, and resume unfinished videos across devices using iCloud. No media is included; files come from a remote server rather than local-file imports.

| Platform | Minimum OS | Xcode scheme |
| --- | --- | --- |
| Apple TV | tvOS 26.2 | BoraMin tvOS |
| iPhone / iPad | iOS 26.0 | BoraMin iOS |
| Apple Silicon Mac | macOS Sequoia 15.0 | BoraMin macOS |

All three targets live in **BoraMin.xcodeproj** and use `com.example.BoraMin`. Builds support physical arm64 devices and an arm64 tvOS Simulator. iOS Simulator and Intel Mac builds are not configured.

## Features

- **Connections:** choose a saved connection, then browse its SMB shares/folders or HTTP base directory. Connections open on demand and reconnect for browsing when needed. Files and folders sort alphabetically together; dotfiles are hidden.
- **HTTP(S) streaming:** browse Caddy or nginx JSON directory listings with independently optional username and password. Stream and seek through validated byte ranges using the existing playback engines and 128 MiB cache, with external subtitles, favorites and Watching support. HTTP connections are read-only; whole-video download fallbacks are disabled.
- **iCloud sync:** synchronize saved connections, credentials, favorites and playback history. Fixed conflicting legacy connection identities that could leave a connection missing on one device or duplicated on another, while preserving existing saved references.
- **Playback labels:** file details show the expected route before duration/size: AVP (AVPlayer), AEP (AetherEngine), or HW9 (original hardware VP9). Visible files are probed in the background, with a bounded local-only metadata cache; Watching also probes visible uncached entries and reuses local results. A label is a route prediction, not a compatibility or decoder-status guarantee.
- **Favorites:** save folder/share paths using the context menu. Favorites sort alphabetically and keep their navigation separate from Files.
- **Watching:** unfinished videos, ordered by last save time. Filenames show progress such as `(80%, 00:12:45)`. Reopening resumes playback; completion returns to the previous screen. **Reset Playback** clears progress and the saved subtitle choice.
- **Audio & Subtitles:** select audio, embedded subtitles, external subtitles, or Off. Uses a sheet on iOS, a popover on Mac, and a system menu above the tvOS scrubber.
- **External subtitles:** load matching `.srt`, `.vtt`, `.ass`, or `.ssa` files from the video's folder. For example, `Movie.mp4` matches `Movie.ass`. ASS/SSA styling is rendered with libass.
- **Settings:** iCloud sync, Display all files, Subtitle Size, and Show Debug Info. Subtitle Size offers 100%, 125%, 150%, and 200%, initially 125%, and is saved per device.
- **File deletion:** delete individual SMB files through the context menu with confirmation. HTTP connections are read-only; folders cannot be deleted.

Manage servers from **Connections** on the main screen. Opening Connections on iOS/tvOS always shows the saved list first, including after browsing a server or a failed attempt. Open an entry to browse it; use its context menu to edit it or choose **Delete Connection…**, or **Add connection…** for an empty form. Deleting asks for confirmation and syncs when iCloud is enabled; server files, favorites and playback history are kept. Give it an optional name and enter its server address and credentials. Leave Share empty to browse available shares. Saving works offline; Connections opens the server only when you choose an entry. An unavailable server has Retry/Edit actions and does not remove favorites or prevent choosing another connection. Passwords are stored in Keychain; server addresses and credentials are never bundled with the app.

## HTTP(S) connections

Choose **HTTP(S)** only when adding a connection, then enter a base directory URL such as `https://media.example.com/videos/` and optional HTTP Basic credentials. Username and password are independently optional: leave both blank for anonymous access, or supply either or both as your server requires. The saved connection type cannot be changed when editing. HTTPS uses normal system certificate validation; HTTP is also supported for explicitly configured servers. Use HTTPS when sending credentials.

Caddy must enable `file_server browse`. BoraMin requests `Accept: application/json`, so the same URL continues serving HTML in a web browser. An `index.html`/`index.txt` that takes precedence over directory browsing must not replace the JSON listing. nginx's `autoindex on; autoindex_format json;` format is also accepted; arbitrary HTML listings are not parsed. Listings are limited to 8 MiB; Caddy's own directory entry limit can also truncate a listing, so configure that server limit for your library size.

The base URL is the browsing root. Folder navigation, favorites, Watching/resume, metadata, matching external subtitles, Keychain credentials, and encrypted iCloud records use the shared app paths. HTTP connections do not offer file deletion. Subtitle matching and playback-engine limitations remain the same as SMB.

Before opening a remote file, BoraMin requests one byte and requires `206 Partial Content` with the correct `Content-Range` and total size. Every subsequent bounded range is validated, including its length and available ETag/Last-Modified identity. Incorrect/ignored ranges, encoded responses, changed files, and early termination fail; no whole-video GET or download fallback is used. Redirects must remain on the same origin and within the configured base path. HTTP media bypasses URLCache and uses the existing 128 MiB in-memory compressed cache.

## Playback

- **MP4 / M4V / MOV:** native AVPlayer playback through the shared remote-file resource loader, except VP9 files using the separate decoder path below.
- **Other MKVs and AetherEngine formats:** AetherEngine uses native AVPlayer when supported, otherwise its software video surface with app-written controls built from standard SwiftUI components.
- **VP9 in MKV / MP4 / M4V / MOV / WebM:** the original hardware VideoToolbox decoder and separate video layer, with AVKit controls. This path supports matching external subtitles, but not AetherEngine's embedded audio/subtitle track selection.

Playback streams requested ranges rather than downloading the whole movie. Each remote stream has a **128 MiB compressed cache**; decoded frames and player buffers use additional memory.

Native sessions retain AVKit's transport controls. iOS playback opens in landscape and native video supports fit/fill pinch zoom. Mac uses native tables, windows, keyboard shortcuts, and full-screen playback.

### Subtitle behavior and limits

External text subtitles and embedded MKV ASS/SSA use the libass overlay; other embedded subtitles retain their native or existing overlay path. Subtitle Size affects libass text, while native captions use system appearance settings.

Selected subtitles, including explicit Off, are remembered only with an unfinished playback position and sync with that position. Completion and Reset Playback clear both. Missing saved tracks stay Off rather than selecting another subtitle.

External subtitles require an identical base filename; language suffixes such as `Movie.en.srt` are not matched. App-rendered subtitles do not follow video into PiP or AirPlay. Font fallback and SRT/VTT conversion can limit fidelity. See [subtitle support and limitations](docs/External-subtitles.md).

Codec/profile support depends on the engine, OS, and device. A recognized extension does not guarantee playback. Software playback and the separate VP9 layer do not inherit every native gesture or thumbnail-seeking feature. See [AetherEngine software playback](docs/AetherEngine-playback.md) and [VP9 investigation](Tests/Native-VP9-investigation.md).

## iCloud

**Sync via iCloud** synchronizes connection profiles, encrypted passwords, favorites, playback positions and subtitle choices, Watching metadata, and supported preferences through the user's private database. Settings provides sync status and **Sync Now**. Offline changes are queued; delivery is asynchronous. Subtitle Size, navigation state, and the active connection remain local. Existing server details, favorites and Watching metadata migrate to saved connection IDs without resetting progress.

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

For the Apple Silicon tvOS Simulator, also run `python3 tools/build_ffmpeg.py --platform tvos-simulator`, then select a tvOS 26.2 or newer simulator under **BoraMin tvOS**. Keep signing enabled so Xcode embeds the simulator CloudKit entitlements. The project chooses separate FFmpeg libraries for simulator and device builds; device libraries cannot be used in the simulator. Simulator behavior does not establish hardware decoder behavior or reproduce every physical-device termination.

For beta archives, uploads, iCloud distribution setup, and release status, follow **[testflight.md](testflight.md)**.

## Development notes

- [Agent guidance and project boundaries](AGENTS.md)
- [Feature and bug-fix history](docs/Feature-history.md)
- [Playback logs and crash reports](docs/Diagnostics.md)
- [Subtitle regression fixtures and checks](docs/External-subtitles.md#local-regression-probe)
- [Device probes and investigations](Tests/README.md)
- [Streaming remux research and limits](Tests/Streaming-remux-investigation.md)
