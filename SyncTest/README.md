# BoraMin for iOS

Normal launches open the full **BoraMin** player on iPhone/iPad: Files, Favorites and Settings, automatic SMB connection/reconnection, streaming playback with native AVPlayerViewController controls, hardware VP9 decoding, saved progress/resume, and the same iCloud stores as Apple TV. The home screen uses standard navigation rows on iOS; file and folder context menus provide Favorite and Reset playback.

- Bundle ID remains `com.example.BoraMin.SyncTest` to preserve existing installed data and Keychain access; the displayed name is **BoraMin**.
- Container: `iCloud.com.example.BoraMin`, private **development** database; zone/type `BoraMinUserData-v1` / `BoraMinUserData`.
- Minimum iOS: 26.0. The supplemental VP9 decoder registration API is available from iOS 26.2; hardware VP9 requires a supported OS/device. Other formats use AVPlayer's system decoding.
- Build the physical iOS arm64 FFmpeg demux/audio libraries with `python3 tools/build_ffmpeg.py --platform ios` (checksum-verified pinned FFmpeg 8.0.1). They live in ignored `vendor/ffmpeg-ios`, separate from tvOS libraries. No software video decoders or networking are enabled in FFmpeg.
- Generate using `python3 tools/create_sync_test_project.py`, then build `BoraMinSyncTest.xcodeproj`, scheme `BoraMinSyncTest`, destination `generic/platform=iOS`, derived data `build/SyncTest`.
- iOS icon: `Assets/BoraMin.icon`, created with Icon Composer from transparent foreground layers extracted from the supplied PNG, on a native purple gradient. Xcode compiles its glass/dark/tinted appearances. Apple TV uses `Assets/BoraMinTV.xcassets` with native layered parallax images.
- Existing real-device iCloud validation below predates the full player. TV probe build commands below are historical; the current companion project targets physical iOS. Build the normal TV player with `BoraMin.xcodeproj`.

## Earlier isolated sync probe

The original synthetic-only probe is still available with `--probe` or `--cloud-action ACTION`. In that mode it uses the separate zone `BoraMinSyncProbe-v1` and type `BoraMinSyncProbe`, and does not access the player's real connections, favorites, passwords or playback history. The remainder of the synthetic test instructions below applies to **probe mode**.

## Build

Generate using `python3 tools/create_sync_test_project.py`. Open `BoraMinSyncTest.xcodeproj` and choose the `BoraMinSyncTest` scheme and a physical iPhone or Apple TV. Use the configured team and development iCloud environment. The generator preserves the original player project and does not bundle private default files. Command-line examples:

```sh
xcodebuild -project BoraMinSyncTest.xcodeproj -scheme BoraMinSyncTest \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/SyncTest -allowProvisioningUpdates build

xcodebuild -project BoraMinSyncTest.xcodeproj -scheme BoraMinSyncTest \
  -configuration Release -sdk appletvos -destination 'generic/platform=tvOS' \
  -derivedDataPath build/SyncTestTV -allowProvisioningUpdates build
```

Both devices must be signed into the same iCloud account; the UI shows a short hashed account fingerprint to confirm the match without displaying an account identifier. This test target has no tvOS User Management entitlement and uses the Apple TV's default iCloud user. Household/profile switching remains a separate production integration task.

## Try the isolated probe manually

Launch with `--probe` first. Use the same **Test run** value on both devices. On one device, choose **Create test data**. On the other, choose **Sync now**. The server, favorite, setting and playback record should appear. Advance/reset playback or add a favorite on either device and sync the other to see the change.

**Work offline** suppresses this app's explicit sync operations without changing the device's network settings. Make edits, restart the app, then choose **Sync now** to upload the durable queue. The checkbox itself starts off again after relaunch. CloudKit automatic syncing is deliberately disabled for this probe so the offline test is reproducible; real background network outages are not simulated by toggling the device's radios.

**Delete this run's test data** deletes only records bearing the current run ID. Sync the other device afterward to see those deletions. Never enter real NAS credentials into this probe; its data is intentionally synthetic.

## Automated device verification

Launch with `--run-id UNIQUE_RUN --cloud-action ACTION` and capture the device console. Run actions sequentially and require `BORAMIN_CLOUD PASS action=...` before continuing:

| Device | Action | Assertion |
| --- | --- | --- |
| iPhone | `seed` | Upload four synthetic records, including encrypted password. |
| Apple TV | `tv-roundtrip` | Fetch/decrypt password into local Keychain; verify favorite/settings; upload playback at 90s and a TV favorite; persist a 20s checkpoint and independent favorite without uploading them. |
| iPhone | `phone-reset` | Receive 90s and the TV favorite, then sync a newer reset. |
| Apple TV, new process | `tv-restart` | Recover two pending offline edits; merge phone reset over the older 20s checkpoint; upload independent favorite. |
| iPhone, new process | `phone-verify` | Receive offline favorite; confirm reset remains and password survives process restart. |
| iPhone | `cleanup` | Delete this run's synthetic cloud records and local Keychain copy. |
| Apple TV | `verify-cleanup` | Apply cloud deletions and remove local copies. |

Example launch (replace DEVICE_ID and UNIQUE_RUN):

```sh
xcrun devicectl --timeout 60 device process launch --device DEVICE_ID \
  --terminate-existing --console com.example.BoraMin.SyncTest \
  --run-id UNIQUE_RUN --cloud-action seed
```

The console stays attached after an action passes. A later devicectl timeout is a logging timeout, not a failed action; use the PASS/FAILED markers. Each subsequent `--terminate-existing` launch creates a real process restart. Test passwords are never logged and are excluded from the local record/queue serialization. They are materialized from Keychain only when constructing an encrypted outgoing record.

## Local persistence and remaining work

On iOS the snapshot is an atomic Application Support file partitioned by hashed CloudKit account ID. tvOS does not provide the same writable Application Support contract: this bounded probe uses account-scoped UserDefaults data with a 200 KB guard. Pending changes, CKRecord system fields and CKSyncEngine state are stored together. The device-only Keychain is also partitioned by account. This probe is not an unbounded production media-history database.

The engine fetches before sending, uses per-record edit timestamps plus operation IDs to merge conflicts, and represents reset as an explicit versioned state. Tests cover the deliberately ordered offline scenario above; arbitrary clock skew, account changes, profile switching, background delivery, encrypted-data resets and production schema deployment still need broader integration testing. Test record deletion is cleanup behavior, not a general production tombstone policy.

The main BoraMin player now uses its own production sync implementation in Shared/ICloudSync.swift, with a separate real-data zone. The probe described in this section remains a bounded synthetic-data test fixture. The companion is not the full iOS video player.

## Verified on October 21, 2026

All seven sequential phases above passed on physical **test device (iPhone 16 Pro)** and **Apple TV 4K (2nd generation)** using the same iCloud account. Test run `20261021-icloud-probe-01` was deleted afterward; deletion propagation to the TV passed on retry after a startup stall. Exported local snapshots on both platforms contained no synthetic password bytes. The initial TV prototype exposed an unwritable Application Support location; the deployed version uses the bounded account-scoped preferences snapshot described above.

## Real integration device checks

`--icloud-sync-check` runs the normal production sync and saves only counts, an opaque content digest and status in `cloudDiagnosticSummary` for comparison without logging connection details or secrets. `--icloud-preference-check disable-and-toggle`, `enable` and `toggle` are regression hooks used with that flag to test that turning sync off queues a display preference locally, and re-enabling transfers it. Tests restore the original preference afterward. Ordinary launches perform no test edits.

Production integration on October 21: the TV and test device matched all real connection fields, one Keychain credential, five favorites, four playback positions and the display preference, with identical record digests and no pending changes. Sync-off retained a queued local operation and re-enable drained it across restart. The final positive toggle/restore check was skipped at the user’s request. Original display preference was restored; ordinary launches have no regression actions.
