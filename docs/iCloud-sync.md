# BoraMin iCloud sync design

Research date: October 21, 2026; implementation status updated October 22. The tvOS, iOS and macOS apps share `Shared/ICloudSync.swift` and the **Sync via iCloud** setting. See the [current README](../README.md), [iOS/device records](../iOS/README.md) and [Mac verification](../MacOS/README.md).

The remaining document preserves the original design proposal and cross-platform/per-profile caveats. Proposed record names and UUIDs below are conceptual, not the deployed schema: the implementation uses one encrypted `BoraMinUserData` record type in `BoraMinUserData-v1`, opaque hash identities, and `kind` fields for server/connection/favorite/position/video/setting records. The container is already configured, not awaiting selection.

The apps use one CloudKit container, `iCloud.com.example.BoraMin`, across tvOS, iOS/iPadOS, and macOS. Store each user's records in their private database and a custom record zone. Keep local persistence so browsing, playback, and password retrieval work without an internet connection. Use CKSyncEngine to synchronize the local changes and apply remote changes. No BoraMin account or custom server is needed.

## Why CloudKit

CloudKit supports all target platforms. NSUbiquitousKeyValueStore is useful for small preferences, but has a 1 MB total/1024-key limit and is designed for infrequent changes. A media history with independent edits, resets, deletes, and frequent checkpoints benefits from separate CloudKit records. Avoid storing an entire collection as a single JSON cloud value: concurrent devices can overwrite unrelated changes.

Important: app-created Keychain items do not synchronize through iCloud on tvOS. Enabling kSecAttrSynchronizable is not a solution for Apple TV. The current ConnectionPreferences implementation also deliberately uses a device-only accessibility class. Keep local passwords in Keychain; synchronize their cloud copies using explicitly encrypted private CloudKit fields.

## Cloud data

| Record | Identity and contents |
| --- | --- |
| ServerProfile | Stable UUID; display name, host/IP, port, username, domain, optional preferred share, encrypted password; operation/version metadata. |
| Favorite | Stable server-profile ID, share, relative folder path, optional display name; deletion state and edit metadata. Deduplicate by server/share/path. |
| PlaybackPosition | File identity, seconds, duration, update metadata, and explicit state: inProgress, reset, or completed. |
| Settings | Small preferences such as displayAllFiles. Device navigation/focus and active playback sessions stay local. |

Use CKRecord.encryptedValues for passwords and other sensitive server/account/path fields from the beginning. Use opaque record IDs; do not put hostnames, passwords or readable paths into IDs. CloudKit cannot index encrypted fields, so fetch zone changes and perform lookups/sorting locally. Private records are available to their owning iCloud account; development and production databases are separate.

Encrypted CloudKit fields are supported by the installed tvOS SDK (tvOS 15+). Unlike app-created Keychain item sync, their encryption is handled by CloudKit. Confirm encrypted field creation/read-back and cross-device decryption on the physical Apple TV and an iOS or macOS test client before rolling out credential sync. Apple's docs describe encryption on-device and stronger key ownership guarantees with Advanced Data Protection; do not promise unconditional end-to-end encryption when ADP is disabled. Never silently fall back to an unencrypted password field.

The local ordinary database/preferences must not contain passwords. Resolve the cloud credential into the account-scoped local Keychain after downloading. A separate credential record may be used if this makes it easier to keep plaintext secrets out of a general-purpose persistent sync queue: persist its pending marker, read its value from Keychain when constructing an outgoing record, and retain the corresponding CKRecord system metadata.

## Sync behavior

- Apply local edits immediately and queue uploads durably. Persist local records, per-record CloudKit system metadata, pending operations, and CKSyncEngine state together. The engine does not persist its own state.
- Fetch on launch/foreground and request a send after important actions. Periodic cloud synchronization is asynchronous, not a guarantee of an immediate device-to-device handoff. Use remote notifications for background change hints and refresh on foreground regardless.
- Preserve existing 15-second *local* playback checkpoints. Coalesce cloud updates (for example once per minute while playing), and request a send when pausing/exiting/backgrounding, resetting, or completing. App suspension may interrupt an immediate upload, so the pending operation must survive relaunch.
- Merge independent records individually. For a given bookmark, use versioned user actions with updatedAt and a stable operation/device tie-breaker; detect server record conflicts and compare edits rather than blindly overwriting the server. Document device-clock limitations of a simple timestamp policy. Never take the maximum playback position: rewinding and rewatching must work.
- Reset/completion are explicit newer operations, not merely absent bookmarks. Preserve sufficient deletion/version history so a delayed offline checkpoint cannot resurrect a reset or a removed favorite. Locally a reset/completed record produces no filename prefix and starts at zero.
- Do not seek a video that is currently playing because another device sent a bookmark. Apply the merged position next time the video is opened.
- Keep local/offline operation available when iCloud is signed out, unavailable, or disabled. Distinguish queued sync from completed sync in Settings.

## Identity and migration

ConnectionPreferences currently remembers one server/account in UserDefaults and stores its password in Keychain. Favorites stores a JSON array in UserDefaults. PlaybackPositions stores up to 500 hash-keyed records in UserDefaults. These are local only; there are currently no iCloud entitlements or CloudKit container configuration.

Import these local values once after associating the local store with the user's iCloud account. Fetch and merge existing cloud records before treating local collections as authoritative. Do not replace remote data with an empty first-run local store. Keep migration version markers, so a repeated import does not duplicate server profiles or favorites. Read existing passwords from Keychain; do not reintroduce default credential resources.

Keep existing playback hash IDs for the first sync release: they already match across devices using the same host/port/share/path/file-size. Those hashes cannot be reversed to recover a filename. If adopting server-UUID-based media identities, migrate bookmarks lazily as matching files are browsed/opened, using the legacy hash as a lookup/alias. Do not silently discard the existing history. A shared server profile UUID eventually lets an address change without losing its favorites/history. Reaching the same NAS via two independently configured aliases requires explicit profile mapping; it cannot be inferred reliably from a path alone.

## Apple TV users and credentials

Configure the tvOS User Management capability to run for the selected Apple TV user; otherwise CloudKit uses the default user. The modern entitlement is runs-as-current-user-with-user-independent-keychain. Its Keychain is user-independent, so Keychain account identities must additionally include the CloudKit account identifier; the current endpoint/account/domain-only password identity is insufficient for household isolation. Scope local sync stores/queues to the same iCloud account, and handle CKSyncEngine accountChange events. Never upload one account's queued data to another account on sign-in or account switch.

Adding the user-management entitlement may change which local preferences container is visible. Preserve the old default user's data through a tested migration before enabling it for existing installations; do not automatically import a household's old shared credentials into every user's iCloud account.

## Project setup and delivery order

1. Create/associate the shared CloudKit container in the Apple Developer account. Enable iCloud/CloudKit and remote notification capabilities, with provisioning that includes them. Add the entitlement file to the project generator's build settings; it must survive regeneration. Enable the chosen tvOS user-management capability with its account-isolation migration.
2. Validate a disposable encrypted credential record on the physical Apple TV and a second platform under the same Apple account, then delete the test record. Verify that another account cannot fetch it. Do not upload actual NAS credentials as an experiment.
3. Add a shared Foundation/CloudKit/Security persistence module independent of the tvOS UI, demuxer, SMB session, and player. Retain local Keychain and local data stores, adding durable sync state and per-record change tracking.
4. Migrate server details, favorites, and playback records. Introduce reset/completion tombstones before publishing history. Add a standard Settings control for iCloud Sync, status/last success, and a manual sync action. Explain that syncing connection passwords is included before first upload.
5. Test device restart, offline editing and reconnect, simultaneous edits, rewind, finish/reset, deletion, sign-out/account switch, tvOS profile switch, unavailable iCloud, Keychain/encrypted-data reset, and development/production containers. First demonstrate bidirectional sync between Apple TV and a minimal iOS/macOS client; shipping those full UI ports is separate work.
6. Promote the encrypted schema to CloudKit production before shipping an App Store/TestFlight version that uses it. Keep private user data out of public/shared databases and logs. Video bytes continue streaming from SMB; they are not uploaded to iCloud.

## Apple sources

- [CloudKit platform support](https://developer.apple.com/icloud/cloudkit/)
- [Private database ownership](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)
- [Keychain synchronization, including the tvOS restriction](https://developer.apple.com/documentation/security/ksecattrsynchronizable)
- [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
- [Encrypted record fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [CKSyncEngine account changes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange)
- [iCloud key-value storage limits](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/StoringPreferenceDatainiCloud/StoringPreferenceDatainiCloud.html)
- [User Management entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.user-management)
- [Personalizing a tvOS app for each user](https://developer.apple.com/documentation/tvservices/personalizing-your-app-for-each-user-on-apple-tv)

## Production deployment

On October 22, 2026 the reviewed schema was deployed through CloudKit Console, without copying development records. Production shows `BoraMinUserData.payload` as Encrypted Bytes and `password` as Encrypted String. The local Mac App Store Connect export was verified to use Production CloudKit and production APNs. Normal development builds remain on Development. See [TestFlight preparation](../testflight.md) for the export workflow, validation and remaining environment-isolation limits.
