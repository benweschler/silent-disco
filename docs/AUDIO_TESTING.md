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

## Host startup / Bonjour failures

If Bonjour registration fails (including macOS `DNS Error: NoAuth`), the host
shows the error and retries once without advertising. Use the iPhone's manual
address connection with the Mac's LAN IP and the displayed TCP port. The port
can change after every restart. Local-network access rules still apply.
The socket fallback does not repair Bonjour authorization. If permission is
already enabled, quit and reopen the Mac app before retrying discovery.
Other listener failures stop hosting and retain the error in the UI and system log.
No dummy-service removal or loopback change is required for this error.

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

## Background-playback diagnostic run (report schema 2)

Rebuild/install both apps once after this native-code update; hot reload does not
load Swift changes. Use the same music file with a 500 ms shared presentation lead:

1. Listen through AirPods with the app foregrounded for 30 seconds.
2. Background the app for 30 seconds.
3. Return, then lock the phone with its screen off for 30 seconds.
4. Wake the screen but leave the phone locked for 30 seconds.
5. Stop audio on the Mac, wait for report collection, and export the report.

Record approximate transition times and audible behavior. Lock/screen state is
user-reported; native notifications record app active/inactive/background state.
Inspect this report before requesting another run. Repeat through the speaker only
if the first report leaves the cause unclear. This update adds evidence, not a fix.

Each listener has `stats.rendererDiagnostics` (timer intervals, scheduling-pass
and packet-queue delays) and `stats.diagnostics` (structured event history).
`playbackReset` snapshots are taken before fading/clearing playback. They include
actual timing error, player sample time, clock offset adjustment, output latency
change, compressed-buffer depth, scheduled samples, next deadline, and
`estimatedPlayableAudioMs`. That estimate uses scheduled minus rendered audio,
adjusted for playback rate; it is null when player timing is unavailable and is
not a measurement of audio heard at the headphones. `rendererStopped` records
normal stop or lifecycle-driven renderer cleanup separately from failure resets.

Events carry generation, sequence, UTC time, local monotonic time, captured clock
offset and `streamSeconds` relative to the Mac presentation anchor. Negative
stream time is possible before the presentation anchor. Lifecycle events capture
time at notification receipt; their clock offset is sampled on the session queue.
Renderer reset offsets are captured on the renderer queue. Stream-start events
include app state; route, interruption, activation and receive-gap events help
correlate transitions with failures. Renderer counters persist through resets but
restart for a new stream generation.

The phone retains 32 events and transmits its latest eight with existing statistics.
The Mac deduplicates and retains 256 events per listener. `retentionOverflow`,
`hostRetentionOverflow`, `transportOmissions` and `observedSequenceGaps` expose
incomplete evidence. Transport omissions count removed event copies, including
repeated copies across snapshots. Stats keep the existing 16 KB control-frame limit.
Old schema-1 reports remain readable; the audio protocol stays at version 1.

Timer delays plus exhausted playable audio suggest scheduling starvation. Resets
with adequate playable audio suggest clock/player/latency calculation issues.
Do not change scheduling horizon, reset threshold or codec until the evidence
supports that change. No full-app or repeated socket tests are needed for this
instrumentation; physical lock/background behavior is validated by the user.

## Lock-related timing correction

Scheduling and timing checks now use the player's full downstream pipeline latency
(`player.outputPresentationLatency`), not hardware latency alone. The fixed Mac
presentation anchor is retained. `outputLatencyMs` still means hardware latency;
`pipelineLatencyMs` and `pipelineLatencyChangeMs` describe the full pipeline.
Do not add Bluetooth or I/O-buffer latency again. Diagnostics also include
`hardwareOnlyTimingErrorMs`, corrected `timingErrorMs`, timestamp validity and sample
rate, and iOS `ioBufferDurationMs`. Unavailable/non-finite observations serialize as
null and cannot drive rate correction or a timing reset.

A timing error must exceed 50 ms with the same sign for 200 ms of valid observations
to trigger a reset. Recovery within threshold, a sign change, invalid timing, or
an observation gap above 100 ms restarts confirmation. `timingCandidateStarted`,
`timingCandidateRecovered`, `timingCandidateInvalidated`, `timingCandidateReplaced`
and `timingCandidateSustained` record transitions. While a large error awaits
confirmation playback rate is 1.0. Underruns and missing-audio recovery remain
immediate; the 100 ms decoded horizon, codec and lead choices are unchanged.

After updating both apps, play the same music at 500 ms for 30 seconds in the
foreground, then perform three lock/wake cycles through AirPods. Note audible
interruptions and stop audio to save the report. Repeat once through the speaker
only if needed. Physical success requires no lock-triggered interruption or reset
loop; these code changes alone do not establish that result. If errors persist,
inspect the report rather than increasing thresholds or declaring success.

## Idle listener background recovery

Before music starts, keep the iPhone app open. iOS may suspend an idle backgrounded
app, preventing heartbeats; the Mac still removes listeners after five seconds of
silence. Reopening checks freshness immediately and replaces a stale connection
without waiting for reconnect backoff. The selected host and listening intent are
preserved, and clock synchronization restarts before joining the current stream.
Explicit Disconnect or Stop listening continues to override automatic listening.
No waiting audio or indefinite idle-background connection is introduced.

Device check: connect and tap Listen, background before audio starts, wait long
enough for the Mac to remove the idle listener, then start music on the Mac.
Reopen the phone: it should reconnect and play without another Listen tap. Repeat
with Stop listening or Disconnect selected first; audio must not start itself.
A manual endpoint still requires a new port if the host itself was restarted.

### Investigating renderer stalls and lock-related timing drift

Playback behavior is unchanged by the scheduling-stall diagnostics. First inspect
`passDiagnostics`: the current partial pass and previous completed pass have separate
sequence numbers. A long decode/PCM/scheduling stage identifies where wall time was
spent; short stage execution plus long timer intervals points toward scheduling.
Wall time includes descheduling, so expensive wall time alone does not prove CPU cost.
Compare sender work/send lateness and both transport timers before blaming receive
gaps on the LAN. Clean earlier runs do not support an inherent hardware limitation.
Use the attached timestamp windows to compare player and output-node progress and
latency/clock changes around timing candidates, while respecting playback restarts.

The next physical run should use a Release iPhone build without a debugger, the same
music file, AirPods, Mac-hosted LAN and 500 ms lead. Play foregrounded for 30 seconds,
background for 30 seconds and return, then perform three lock/wake cycles with 15
seconds locked and screen off each time. Mark audible disruptions, stop on the Mac,
and inspect the report before requesting further runs. Do not change the 100 ms
horizon, 50 ms/200 ms decision, lead choices or codec during this diagnostic step.

Use the Mac's fixed **Mark phone transition** menu immediately before each phone
action. It marks your intended action approximately, not an automatically detected
lock. Use **Wake screen while locked** separately from **Unlock phone**. Protected-data
notifications provide a complementary public iOS signal, but passcode configuration
and notification delivery affect it; do not treat their absence as proof that the
phone stayed unlocked. Compare markers, protected-data events, lifecycle events and
timestamp windows together.
