# Silent Disco Listener

Flutter iOS diagnostics app for the offline-LAN experiment. Target test device:
iPhone 14 Pro Max running iOS 18.6.2. No audio playback is implemented yet.

Install a signed build, join the Mac-hosted Wi-Fi, then use **Find hubs / retry**
and **Connect**. Run Connectivity (30 seconds) before the 10-minute baseline.
Every profile is capped at 10 minutes. Keep the app visible during tests.

See [setup and rollback](docs/OFFLINE_LAN_SETUP.md),
[protocol](docs/DIAGNOSTIC_PROTOCOL.md), and [validation](docs/VALIDATION.md).
The setup guide describes commands run on the Mac server, not the phone.

`flutter test` covers UI interactions. `swift test` on macOS tests the matching
native protocol/engine independently of Flutter. Native diagnostics sources and
fixtures are mirrored in the server repository; keep changes synchronized.
