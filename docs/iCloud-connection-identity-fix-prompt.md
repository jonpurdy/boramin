Fix BoraMin's iCloud connection identity reconciliation bug on all platforms.

Work in `the BoraMin checkout`, using the latest working tree on `webdav-support`. Read AGENTS.md first. Preserve the HTTP implementation and unrelated fixes; leave `_to do.txt` alone. Do not revert or overwrite uncommitted work.

Observed on October 30, 2026:
- The iPhone 16 Pro has the intended connection set: one `100.121.106.48` and one `172.16.0.9`.
- Mac has only `172.16.0.9`.
- Apple TV has two `100.121.106.48` profiles, plus `172.16.0.9`. The duplicate profile keys are legacy hash `d0e35538af50f4f2ef128016dea819a8a48747df5747f8fb4aafe4a88c040ac7` and UUID `0628EBE3-19D5-4727-9329-9938C98D7D30`.
- Mac and Apple TV have sync enabled, the same cached cloud owner, and recent successful sync times. Waiting for sync alone did not reconcile the lists.
- The Mac cloud cache contains an older active server record whose record identity matches the legacy profile hash, but whose payload `fields.id` incorrectly contains that UUID. A separate newer tombstone targets the UUID with its matching record identity.
- Active legacy-record identity: `f2ce3191dd1951c03c633a455d8746d35fa2c4443d98ced8220f2c696ff7b85b`, timestamp October 26, 2026 22:19:11 Toronto time.
- UUID tombstone record identity: `cdd1a9fa49852d55039a70cdbc614a51b57a2e4c70d2865edf1748770be8d928`, timestamp October 30, 2026 10:59:33 Toronto time.
- These conflicting records predate the HTTP implementation. This is an identity reconciliation problem, not evidence that HTTP changed SMB identities.

Investigate `Shared/ICloudSync.swift` (loadCache, outbox restoration, snapshots/capture, merge, apply, runSync and handleEvent) and `Player/ConnectionPreferences.swift`. Currently server apply trusts `fields.id`, while cached records are reapplied in dictionary order. Confirm the complete cause with focused fixtures before choosing a repair; do not assume payload IDs and immutable cloud record identities agree.

Implement deterministic, idempotent handling of legacy records, modern profile IDs, aliases and tombstones. Preserve stable profile IDs and existing favorite/Watching references, bookmark keys, subtitle selections, credentials, and valid distinct accounts/shares on the same host. Do not deduplicate solely by server address or indiscriminately revive/delete records. Resolve which identity each record actually owns, and ensure stale aliases cannot resurrect deleted profiles or delete a different valid profile. Handle already-corrupted caches/outboxes as well as newly fetched records. Preserve all existing SMB and HTTP profile formats and credential isolation.

Add regression fixtures covering both record application orders, repeated synchronization/relaunch, cold/cache/outbox restoration, stale active aliases versus newer tombstones, pending local edits, profile edits/deletion, favorite/Watching references, and legitimate same-host profiles. Verify all permutations converge to the intended two connections without changes to unrelated user data.

Use synthetic metadata and targeted password-free diagnostics. Do not export whole device preferences when a narrow profile diagnostic suffices; never print/copy passwords or read local default_*.txt files. Do not reset CloudKit zones, clear app data, switch iCloud environments, or manually delete live records as a shortcut. Keep source entitlements on Development. Build affected platforms, run relevant model/sync checks and the main suite as appropriate, and keep detailed evidence under ignored build/. Report what is proven versus inferred. Do not deploy or mutate live connection data until the repair is tested and that action is requested.
