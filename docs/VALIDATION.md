# Validation record

## Commands

From either project:

```sh
flutter analyze
flutter test
swift test
```

The Swift package builds the same native networking/protocol sources used by the
apps, excluding the Flutter bridge. It has no downloaded dependencies. Its normal
suite uses deterministic fixtures and clocks; the network integration case skips
unless explicitly enabled:

```sh
SD_NETWORK_TEST=1 swift test --filter DiagnosticTests/testLocalhostConnectivityAndCleanup
```

That integration test runs the real host and phone engines over local TCP/UDP for
30 seconds and checks counter exchange and cleanup. It does not validate Bonjour
across devices, sandbox permission UI, Wi-Fi, or the offline hotspot.

Builds:

```sh
# Server project
flutter build macos --release
# iPhone project
flutter build ios --no-codesign --release
```

The unsigned iOS build checks compilation; install a signed build for physical use.

## Automated results — 2026-10-09

- Flutter analysis: passed in both projects.
- Flutter widget tests: 3 passed in each project (6 total).
- Native deterministic tests: 6 passed; packet fixtures, framing, counters, pacing,
  retry limits, fake-clock deadlines, and the 600-second cap.
- Real TCP/UDP localhost integration: passed (30-second traffic run plus drain),
  with zero downstream/upstream missing packets and successful listener cleanup.
- Real socket lifecycle integration: passed; background interruption, foreground
  reconnection, no automatic run restart, and cleanup.
- macOS Release build: passed.
- iOS unsigned Release build: passed. This is not an installable signed build.
- Project/plist/entitlement syntax: passed.
- Mirrored native sources, Dart diagnostics screen, and packet fixture: identical
  across the two repositories.

The two socket tests were explicitly run separately. A normal `swift test` skips
these cases unless `SD_NETWORK_TEST=1`; this keeps the default test loop quick.
No hotspot settings were changed during implementation.

## Physical step 1 evidence — 2026-10-10

Observed from the saved reports and user test notes:

- Mac-hosted offline LAN, discovery and connectivity worked on the stated hardware.
- Release baseline with Mac Bluetooth off: 600 seconds, 29,991 submitted packets,
  zero downstream/upstream missing, p95 RTT 11.71 ms, max phone receive gap 362.41 ms.
- The original synthetic gate remains **review**, because the gap exceeds 250 ms.
- Release baseline with Mac Bluetooth on (per user context): 133 downstream missing
  (0.443%), p99 RTT ~1,061.89 ms, max receive gap ~3,831.89 ms.
- A Release baseline was interrupted at ~42 seconds; this remains an unresolved incident.
- Phone-lock test interrupted at ~21.6 seconds as expected for foreground diagnostics.
- These observations justify proceeding to audio; they do not establish audio reliability.
- On 2026-10-10, `127.0.0.1` was missing from lo0 while `10.10.10.1/32` was present.
  The user restored the standard loopback alias; both addresses were verified afterward.
- Wi-Fi/server recovery, permission restoration, reboot repeatability, full rollback,
  and two-device acoustic synchronization remain unverified.

## Physical acceptance checklist (not all completed)

Hardware: Mac on macOS 15.7.5; iPhone 14 Pro Max on iOS 18.6.2.

- [ ] Manual offline hotspot works and assigns DHCP address.
- [ ] USB unplugged, cellular disabled, Mac upstream disconnected.
- [ ] Bonjour discovery within 10 seconds after permission/join.
- [x] 30-second connectivity run.
- [x] One 10-minute baseline, saved report, initial network gates assessed (review).
- [ ] Short Wi-Fi/server interruption and recovery checks.
- [ ] Permission denial/restoration and lock/foreground recovery.
- [ ] Reboot and repeat only the 30-second connectivity run.
- [ ] Rollback restores normal network configuration.

No 60-minute run is required. The optional 10-minute three-channel preview is not
an acceptance requirement. No physical-device result should be inferred from
build success or local socket tests.

## Step 2 audio automated validation — 2026-10-10

- Flutter analysis: passed in both projects.
- Flutter widget tests: 6 passed per project (12 total), covering original diagnostics,
  audio control gating, listener controls and report presentation.
- Native audio suite: 11 passed, including Opus round-trip/lookahead alignment,
  44.1 kHz mono file conversion and looping, framing/packet validation, clock estimation,
  jitter/reordering/loss bounds, gap incidents, fake-time pacing/cap, listening lifecycle,
  and two real localhost clients with late joining, disconnect isolation and final-frame signaling.
- Original native diagnostics: all 8 passed, including both opt-in real socket/lifecycle tests.
- Both native packages and bridges remain mirrored; automated comparison passed.
- All 278 bundled Opus upstream files verified against the pinned archive and stored hashes.
- Xcode project and property-list syntax passed.
- Final macOS Release, iOS unsigned Release and iOS simulator builds passed.
- The Opus license was verified inside both device application bundles.

Commands added for this milestone:

```sh
swift test --package-path NativeAudio
SD_AUDIO_NETWORK_TEST=1 swift test --package-path NativeAudio
python3 scripts/verify_opus.py
python3 scripts/check_mirrors.py
```

Physical audio acceptance remains pending. No automated test establishes Bluetooth acoustic
latency, real iOS lock-screen continuity, or two-phone synchronization. See AUDIO_TESTING.md
for the short device checks and one ten-minute listening run. Builds are compilation evidence.
