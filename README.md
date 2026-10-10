# Silent Disco Listener

Flutter iPhone listener for single-channel offline-LAN audio and the original synthetic diagnostics.

Run `flutter run --release -d <iphone-device-id>` (use Release for physical tests). Start the Mac audio host, connect
and tap Listen in this app, choose a test signal or local music file, then
start a run. The native sender caps runs at ten minutes. No USB capture or DJ monitor yet.

- [Audio setup and physical test checklist](docs/AUDIO_TESTING.md)
- [Audio protocol and timing](docs/AUDIO_PROTOCOL.md)
- [Original LAN setup and rollback](docs/OFFLINE_LAN_SETUP.md)
- [Validation record](docs/VALIDATION.md)

Audio and LAN diagnostics are separate, mutually exclusive modes. Both projects contain
identical native audio/diagnostics cores and a pinned offline-buildable Opus package.
Builds never depend on the sibling checkout.

```sh
flutter analyze
flutter test
swift test
swift test --package-path NativeAudio
SD_AUDIO_NETWORK_TEST=1 swift test --package-path NativeAudio
python3 scripts/verify_opus.py
python3 scripts/check_mirrors.py
```

The last check requires the other checkout. Audio socket integration is opt-in and runs
in seconds. Signed iPhone installation, locked-screen Bluetooth playback, and acoustic
synchronization require physical testing; builds and simulated listeners do not prove them.
