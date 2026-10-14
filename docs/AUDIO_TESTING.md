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
   shared presentation lead at 1250 ms; add notes and offline confirmation, then **Start audio**.
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

The default shared lead is 1250 ms; 500/750/1000 ms remain available for better networks.
The lead also covers pipeline latency, codec lookahead, and the 20 ms scheduling guard.
Already available packets may be decoded ahead; absent packets wait until that guard.
The PCM refill target does not itself force early loss decisions.
Bluetooth coexistence on the Mac remains a later controlled comparison. Prefer a 5 GHz
hotspot channel if offered; record channel/band and headphone models in the notes.

Two-phone acoustic skew (target 20–30 ms) remains pending: capture simultaneous click
outputs on one recording timebase. Simulated clients do not substitute for this test.
USB capture, Mac DJ monitoring, three channels and ten-person capacity are not included.

## Policy 4: listener scheduling and timing acceptance

Rebuild **both** apps and install a signed Release iPhone build. Hot reload cannot
load these native changes. Run without a debugger and leave the optional latency
probe off for acceptance. Reports include `buildInfo.buildRevision`, the native
`sourceFingerprint`, and `diagnosticPolicyVersion: 4`. Xcode creates the provenance
resource on every Runner build; package tests explicitly report unknown provenance.

Use the same music and AirPods on the Mac-hosted LAN at **1250 ms**. Start with
30 seconds foregrounded and 30 seconds backgrounded, return, then perform repeated
lock / wake-screen-while-locked / unlock cycles. Follow with a ten-minute mixed run.
On the Mac each transition is a single-click button. Space marks one audible
interruption per press; repeats do not trigger additional actions. Typing, dialogs,
modifier-key combinations, and inactive runs retain normal keyboard behavior.
Stop on the Mac and wait for final statistics before inspecting the saved report.

Acceptance requires zero marked audible interruptions, no latency-read-induced
scheduler starvation, no premature PLC for packets delivered within the available
budget, and zero timing-only recoveries. Fewer resets alone are not success.
Two-listener acoustic skew must separately meet the 20–30 ms target on a shared
recording timebase, including transitions and recovery. Reports remain explicitly
`acousticSynchronization: unverified`; software estimates cannot certify that target.

If app scheduling is healthy but delivery exceeds budget, compare the same test on
ordinary Wi-Fi. If only Bluetooth shows the timing excursions, compare speaker output
and collect simultaneous acoustic/timestamp evidence before changing compensation.
Do not infer that either LAN hardware or Bluetooth is inherently incapable from a
receive gap or a timestamp excursion alone. Physical acceptance is still pending.

### Latency getter attribution

`rendererDiagnostics.latencySnapshot` records graph epoch, query start/completion,
age, values, validity and per-getter aggregates. The measured names are
`sessionLookup` and `ioBufferDuration` (iOS), `outputNodeLookup`, `presentationLatency`,
and `outputPresentationLatency`. Counts, maxima and threshold exceedances accompany
up to four recent slow reads with call site and epoch. Values are wall time, not CPU
time; a long call can include thread descheduling. Getter aggregates are graph-scoped.
Snapshots older than three seconds disable timing correction while current-graph
playback keeps refilling from the last valid snapshot. New graphs need a valid snapshot.

For a targeted attribution run only, enable the launch argument
`-SDAudioLatencyProbe YES` in the iOS scheme, or `SD_AUDIO_LATENCY_PROBE=1` in the
process environment. This invokes the former 200 Hz tick + 50 Hz packet query cadence
on the **isolated control queue**, never on the scheduler. It deliberately adds
load; `latencyProbeEnabled` marks its reports. Disable the argument/environment
(or use `-SDAudioLatencyProbe NO`) before acceptance runs. This reproduces query
cadence, not the old queue placement, and need not reproduce every old stall.

In Instruments System Trace, correlate the `dev.silentdisco.audio` / `Latency`
`Latency getter` signposts with thread states, scheduler gaps and render progress.
The signposts name the property, call site and graph epoch. A getter's wall duration
alone does not prove synchronous IPC or a framework lock. If monitor reads still
stall rendering globally, investigate the shared framework wait before claiming a fix.

### Read the new evidence

- `timingSummary`: `starting`, `stable`, `outputTransition`, `timingUnavailable`;
  compact start/end output sample-host pairs, measured slope, phase
  error, and diagnostic episode. Compact summaries survive observation-window trimming.
- `sourcePresentationAnchorMacSeconds` stays fixed for the stream (wire anchor minus
  encoder lookahead). `sourceSampleBase`, `playbackEpoch`, and `graphEpoch` distinguish
  local player origins from the shared source timeline. A rejoin does not erase it.
- `estimatedPlayableAudioMs` projects queued minus consumed source samples using the
  paired player timestamp, varispeed and observed output progression. Null means
  unavailable, not empty. `nextConsumptionDeadlineMs` retains negative values;
  `nextRenderingDeadlineMs` is the separate nominal source/host deadline.
- `compressedBufferMs` counts all stored encoded packets; `contiguousEncodedMs`
  counts usable consecutive packets. Neither is an acoustic measurement.
- `packetAdmission` identifies the last callback, admission, sequence and remaining
  consumption-deadline margin. `maxAdmissionDelayMs`, mailbox overflow, reorder depth,
  and `lateAfterPLC` separate queue delay, reordering and late concealment arrivals.
- `recoveryCounts` separates scheduler starvation, missing audio, session/graph
  recovery and decoding failure; timing-only recovery must remain absent. User marks remain independent.
- `passDiagnostics` retains stage wall times and previous/current pass sequences.
  Latency reads are now exclusively in `latencySnapshot`, never in scheduling stages.
  Timer intervals measure the 5 ms fallback timer, not coalesced packet/refill wakes.

Raw error is not permission to reset during an output transition. More than 2%
output-rate deviation over at least 200 ms, or a timestamp discontinuity, enters
transition handling. Reacquisition requires 500 ms within 0.5% of nominal output
progress. Raw residual errors above 50 ms and timing uncertainty hold rate at 1 and remain
visible without stopping the player. After three seconds an episode emits one
`timingDegraded`; after valid fresh stable phase is within ±50 ms for 500 ms it emits
`timingEpisodeEnded` and permits ±0.1% correction again. The source anchor never moves.
Real starvation and interruptions still recover independently.

Capable peers deliver events incrementally with acknowledgements and one in-flight
batch, retaining 256 events on each side. Retries deduplicate; explicit eviction ranges
explain evidence loss. Legacy peers keep the latest-eight snapshot behavior.
Final counters are immutable snapshots taken before cleanup and independent of graph
teardown. The host waits for counters and required event sequences, bounded by lead +
five seconds. Inspect `finalization` for missing IDs and the exact unresolved stage.
Reports remain schema 2 and frames remain within 16 KB.
Protected-data notifications indicate file-protection state, not precise lock/wake
state; Mac transition markers record approximate user actions.

An older listener that omits `maxLeadMs` supports at most 1000 ms. The host refuses
to start 1250 ms with an already listening incompatible peer. An incompatible late
listener stays connected but receives no media/configuration for that run, with an
explanation on its host row. Update it or choose a supported shared lead for the next
run; listeners never independently delay the shared stream.

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

## Policy-4 focused transition run

1. Rebuild both apps in Release and install the signed phone build. Leave
   `SDAudioLatencyProbe` and `SDAudioTrace` off. Use 1250 ms and the same music/output.
2. Perform three lock / wake-screen-while-locked cycles and one unlock. Mark each
   transition on the Mac and mark audible interruptions with Space. Stop and wait
   up to 6.25 seconds for report completion.
3. Verify zero timing-only recoveries, retained degraded/end episode summaries,
   complete counters (or precise finalization reasons), and a lifecycle for each real
   recovery. Run `python3 scripts/analyze_audio_report.py <report.json>` for a compact
   separation of episodes, recoveries, PLC, stalls and user marks.
4. Capture a short 60–90 second repeat in Instruments Audio System Trace with thread
   states and application signposts. Profile Release without LLDB. Enable the launch
   argument `-SDAudioTrace YES` or environment `SD_AUDIO_TRACE=1`; confirm
   `buildInfo.traceEnabled: true`. Keep the latency-cadence probe off. Correlate
   Pipeline `Audio operation` intervals (individual timestamp calls, scheduler stages,
   graph stop) and Latency getter intervals with blocked/runnable thread states and
   stacks. Wall duration and overlapping intervals alone cannot identify a shared lock.
5. Disable tracing. Record two listeners simultaneously on one recording timebase
   using the click signal. Measure relative delay before, during and after transitions
   and recoveries; retain the unverified synchronization label until 20–30 ms passes.
6. If the short run is clean, proceed to ten minutes of mixed transitions. Compare
   ordinary Wi-Fi if delivery exceeds budget; compare speaker output if excursions
   appear limited to Bluetooth.

`timestampCalls.aggregate` gives per-call count/max/threshold counts; `slowCalls`
retains graph/playback epochs and monotonic intervals. `recoveryTimeline` retains
software decision-to-stop and stop-to-observed-progress intervals, never acoustic
silence. `packetIncident` freezes PLC/gap/recovery evidence; summaries and explicit
omission ranges survive trimming. `receiveDiagnostics` includes arm/callback/rearm
intervals and `sessionQueueDelay`; it does not claim a device packet arrival time.

The earlier batch cannot establish why each of its six final snapshots was missing.
A deterministic blocked-control-queue test establishes that teardown-dependent final
reporting can miss a fixed deadline; policy 4 removes that dependency and labels the
remaining stages. Timestamp instrumentation attributes future slow calls but does
not itself fix the observed 85 ms scheduler stall. Physical validation remains pending.
