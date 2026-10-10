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

## Physical acceptance — PENDING

Hardware: Mac on macOS 15.7.5; iPhone 14 Pro Max on iOS 18.6.2.

- [ ] Manual offline hotspot works and assigns DHCP address.
- [ ] USB unplugged, cellular disabled, Mac upstream disconnected.
- [ ] Bonjour discovery within 10 seconds after permission/join.
- [ ] 30-second connectivity run.
- [ ] One 10-minute baseline, exported report, initial network gates assessed.
- [ ] Short Wi-Fi/server interruption and recovery checks.
- [ ] Permission denial/restoration and lock/foreground recovery.
- [ ] Reboot and repeat only the 30-second connectivity run.
- [ ] Rollback restores normal network configuration.

No 60-minute run is required. The optional 10-minute three-channel preview is not
an acceptance requirement. No physical-device result should be inferred from
build success or local socket tests.
