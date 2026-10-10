# Single-channel audio acceptance

## Configuration to keep

Keep `Silent Disco Offline` (10.10.10.1/32). Between tests turn Internet Sharing off,
rejoin the normal Mac Wi-Fi, and restore normal phone cellular/Airplane Mode settings.
For a test, reuse the existing sharing configuration. The apps do not manage it.

**Check `ifconfig lo0` after changing the dummy service or rebooting.** On the test Mac,
creating/configuring the dummy service left `10.10.10.1` present but removed
`127.0.0.1`. This broke Flutter tests and other localhost services. If 127.0.0.1 is
missing, restore it alongside the experiment address:

```sh
sudo ifconfig lo0 inet 127.0.0.1 netmask 255.0.0.0 alias
```

The user restored it on 2026-10-10; both addresses were verified afterward. Persistence
after reboot remains untested. Never remove 127.0.0.1. Full experiment removal is
optional; follow OFFLINE_LAN_SETUP.md only when retiring the setup.

## Install and play

1. Build the Mac app with `flutter build macos --release`. Build/install a signed
   iOS Release app through Xcode or `flutter run --release -d <device-id>` in the
   phone project. An unsigned build cannot be installed directly.
2. Enable Internet Sharing, disconnect Mac upstream connections, unplug phone USB,
   enable phone Airplane Mode, then reenable Wi-Fi **and Bluetooth**. Join the hosted LAN.
3. Initially keep Mac Bluetooth off. Connect headphones to the iPhone. Start at low volume.
4. Mac: **Start audio host**. Phone: **Find audio hubs / retry**, **Connect**, then **Listen**.
5. Mac: choose click track/test tone or a local unprotected music file. Leave the
   shared presentation lead at 500 ms; add notes and offline confirmation, then **Start audio**.
6. Verify a short speaker check and a short headphone check. The host has no local monitor.
7. Run one ten-minute music test mostly with the phone locked. Files loop; native sending
   stops after 600 seconds. Stop Audio finishes queued playback and saves a report.
8. Export the report from the Mac. Files also persist under the app sandbox's
   Application Support/SilentDiscoAudio/Reports (latest 20); synthetic reports are separate.

The LAN diagnostics button stops audio and opens the original foreground-only test screen.
Returning stops diagnostics before returning to audio. Reconnect/restart explicitly.

## Short recovery checks

- Disconnect headphones: listening stops instead of falling back unexpectedly to speaker.
  Reconnect the headphones and tap Listen. Lock-screen Play/Pause controls this listener only.
- Toggle phone Wi-Fi and restore it: the app retries with 1/2/4/5-second delays and rejoins
  the current timeline. For a prolonged background outage, reopen the app; background
  execution is not guaranteed once useful audio stops or the OS suspends the process.
- Restart the host: Bonjour connections resolve the service again. Manual IP connections
  require updating the port if the restarted server chose a new one.
- Interrupt playback (for example another app taking audio), return, and verify recovery.
  A system interruption without permission to resume requires tapping Listen.
- Stop/start another source: no stale audio from the earlier generation should play.

## Interpret reports

Run completed means the sender ended normally, not that every listener had clean playback.
Needs review includes missing final counters, packet/render loss, sender overruns, queue
limits, playback errors or resynchronization. Intentional stopping is recorded separately
from reaching the cap. Disconnected listeners retain incomplete counters and a reason.

Use **Mark audible interruption** on either app during playback to timestamp a subjective
dropout in the report; these marks are separate from engine counters. Record headphone
models and other context in the run notes before starting.
A network gap can be absorbed by buffering; packet-loss concealment may hide a missing frame.
Conversely a Bluetooth dropout may occur after audio leaves our engine and evade our counters.
The report's timing error is a render/clock estimate, **not acoustic synchronization**.

Try 750 or 1000 ms lead if needed. The lead also covers reported output latency and the
short PCM scheduling horizon; it is not all available as network jitter tolerance.
Bluetooth coexistence on the Mac remains a later controlled comparison. Prefer a 5 GHz
hotspot channel if offered; record channel/band and headphone models in the notes.

Two-phone acoustic skew (target 20–30 ms) remains pending: capture simultaneous click
outputs on one recording timebase. Simulated clients do not substitute for this test.
USB capture, Mac DJ monitoring, three channels and ten-person capacity are not included.
