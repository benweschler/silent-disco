# Audio protocol v1

This is an experimental unencrypted transport for the password-protected test LAN.
Tokens correlate UDP to a TCP session; they are not encryption or user authentication.
Audio mode and diagnostics mode are mutually exclusive. Existing SDD1 diagnostics remain v1.

## Discovery/control

Bonjour `_sdaudio._tcp`, TXT version=1, name Silent Disco Audio. Ports are OS-assigned;
peer-to-peer links are disabled. Up to ten TCP peers have independent tokens, readiness,
UDP send budgets and counters. No packet is echoed as part of audio streaming.

TCP uses newline-delimited UTF-8 JSON, max 16,384 bytes, with mandatory string `type`.
Split/coalesced reads are supported; malformed/oversize frames close the connection.
Unknown types are ignored. Integers that identify generations travel as decimal strings.

- `hello(version=1,name,maxLeadMs=1250 optional)` → `welcome(version=1,token,udpPort)`; token is 16 random UUID bytes in base64.
- Client resolves UDP against the actual TCP peer IP, sends registration each second until
  acknowledgment, then `ready`. Host validates the token and matching TCP peer IP.
- `listen(enabled)` toggles delivery for that listener. A late listener receives stream configuration.
- `clock(id,t1)` → `clockReply(id,t1,t2,t3)`; phone records t4 on receipt. Host-minus-phone offset
  is ((t2-t1)+(t3-t4))/2. Reject negative or >=250 ms RTT; retain up to 32 samples/30 seconds,
  use the median offset of the five lowest-RTT samples. Require four samples. Refresh every
  two seconds after startup; expire the estimate after ten seconds without a valid reply.
- `stream(generation,anchor,lead,lookahead,rate=48000,frames=960,channels=2,codec=opus,source)`.
  Anchor is the Mac monotonic presentation time for source sample zero. Lead is 0.5/0.75/1.0/1.25 seconds; default 1.25.
- `stop(generation,lastSequence)` marks the final frame (no PLC after end-of-stream), drains lead+150 ms, stops the renderer and returns final `stats`.
- `audibleIssue` records a listener-reported audible interruption separately from measured counters.
- `stats(generation,stats,final)` once/second and at stop; `heartbeat` every second.

Five seconds without control traffic or ten seconds without readiness disconnects the peer.
Retries use 1, 2, 4, then 5 seconds. Bonjour endpoints are rediscovered, never pinned to an old port.
Explicit stop/listener removal overrides automatic resume. Background suspension may require foregrounding.

## UDP layout (big-endian)

| Offset | Bytes | Meaning |
|---|---:|---|
| 0 | 4 | SDA1 |
| 4 | 1 | version 1 |
| 5 | 1 | kind: 0 register, 1 acknowledgment, 2 media |
| 6 | 2 | channel 0 (only channel supported) |
| 8 | 16 | per-listener session token |
| 24 | 8 | generation (nonzero for media) |
| 32 | 8 | source frame sequence, 0–29,999 |
| 40 | 8 | encoder input sample position = sequence × 960 |
| 48 | 8 | IEEE-754 Double bits, Mac monotonic presentation seconds |
| 56 | 2 | Opus payload length |
| 58 | variable | raw Opus packet; total datagram <1,200 bytes |

Registration/ack have zero generation, sequence, sample, time, length. Media requires a finite
nonnegative timestamp and nonempty payload. Presentation is anchor + sequence×20 ms −
encoder lookahead/48000; the first decoded samples include codec startup delay. Clients validate
the timestamp against configuration. Wrong tokens/generations, duplicates, late and oversize packets
are ignored. A sequence advances with the source timeline even if the sender misses a deadline.

## Audio and bounds

Pinned libopus 1.6.1, 48 kHz stereo, 960 frames, 160 kbps constrained VBR, music signal,
complexity 5, no DTX, no neural enhancements. Native file decoding loops with bounded PCM
buffers and resamples with AVAudioConverter. No entire-file PCM allocation or Dart audio path.

The encode queue has two pending transport deliveries maximum. Each peer has at most four
pending UDP sends and eight pending TCP writes. Scheduling emits the current frame only;
expired frames are skipped. Encoded jitter storage is capped at 100 packets/two seconds;
the mailbox and admitted jitter store share that 100-packet budget. Packet wakes are
coalesced. PCM refilling targets 250 ms of consumption headroom with a 300 ms cap,
at most six frames / 5 ms per scheduling pass. Absent packets wait until the
20 ms consumption guard before PLC; available packets can be decoded earlier.

Output scheduling subtracts the full player.outputPresentationLatency once. Hardware
latency and I/O duration are diagnostic values, not additional delays. A dedicated
serial control queue owns graph lifecycle and latency reads; scheduler operations
use epoch-validated immutable snapshots. The scheduler relinquishes its graph lease
before control work replaces/stops a graph. Reads refresh at startup, after a graph
rebuild, and every second. Invalid refreshes retain the last valid current-epoch value;
values older than three seconds suspend timing correction without blocking refill.

The source anchor is the wire anchor minus codec lookahead; it stays fixed across
local playback epochs. Player source-sample bases distinguish their local zero points.
Stable output uses bounded ±0.1% varispeed correction. Output progress >2% from nominal
over >=200 ms or a discontinuity suspends raw phase resets; >=500 ms within 0.5%
reacquires stability. Stable phase error above 50 ms for 200 ms permits one controlled
20 ms fade/rejoin. An unresolved transition/observation failure permits one attempt
after three seconds. The latch survives local restarts until stable phase is within
50 ms for 500 ms. This is a render-time policy, not an acoustic synchronization claim.

Six consecutive missing frames use PLC (120 ms); the final frame fades and the player
rejoins after it drains. Local recovery retains future encoded packets and the
committed sequence boundary, so a late packet cannot replace already decoded/PLC
content. New generations and explicit shutdown clear encoded storage.

`maxLeadMs` is optional in hello; absence/invalid values mean the legacy 1000 ms
maximum. The new listener advertises 1250. Starting a run is rejected if an already
ready, listening peer cannot support the selected lead. Late incompatible peers
remain connected but receive neither stream configuration nor media; the host row
explains the incompatibility. Lead changes require a new run. UDP format and protocol
version stay unchanged; older hosts ignore the extra hello field.

Snapshots travel over `silent_disco/audio/events`; commands over `silent_disco/audio`:
selectMode, snapshot, startHost, stopHost, browse, connect, disconnect, setSource, pickFile,
setBuffer, startStream, stopStream, listen, stopListening, markAudibleInterruption, exportReport. Lifecycle and route
commands remain native. Reports retain final/incomplete counters, gap counts/durations,
route and interruption events, and always label acoustic synchronization unverified.

## Optional diagnostic evidence

Protocol version 1 statistics may include `rendererDiagnostics` and `diagnostics`.
The latter contains up to eight recent run-scoped events with sequence numbers,
generation, UTC/monotonic timestamps, captured clock offset and stream-relative
time. The receiver deduplicates and accumulates evidence for schema-2 reports.
Evidence is bounded and trimmed before serialization to the existing 16 KB frame
limit; omission/overflow and sequence-gap counters make truncation explicit.
Peers without these optional fields remain compatible. Playback commands and media
packets are unchanged. See AUDIO_TESTING.md for diagnostic field interpretation.

Timing diagnostics additionally distinguish full `pipelineLatencyMs` from hardware
`outputLatencyMs`, preserve hardware-only versus corrected timing errors, and record
timing-state transitions and compact output-clock summaries. These are additive schema-2/protocol-1 fields.

On foreground return the listener replaces a connection with more than five seconds
of receive silence and bypasses reconnect backoff for that attempt. Host selection
and listening intent persist; explicit Disconnect/Stop listening take precedence.
Idle background execution is not guaranteed and the host heartbeat timeout remains
five seconds. No additional wire messages or protocol version changes are required.

### Scheduling-stall evidence (additive schema 2)

`rendererDiagnostics.passDiagnostics` distinguishes `completedPass` from
`currentPartialPass`, each with sequence, start time, decoded-frame count and stage
wall times. `lastSchedulingPassMs` remains the previous completed pass duration.
Stage maxima distinguish single-call and whole-pass maxima; counts, decoded frames,
slow passes and suppressed slow events survive playback resets and reset on a new
stream generation. Stages cover timestamp/observation reads, rate changes, Opus decoding, PCM preparation,
scheduling/play and playback stops. Latency getter measurements are isolated in
`latencySnapshot`, not renderer pass timing. These measure wall
time, including thread descheduling; they are not CPU-time measurements.
`slowRendererPass` (>20 ms) is emitted at most once per second.

`timingObservations` contains up to 16 native observations at 100 ms spacing:
paired player/node timestamps, separately observed output-node timestamps, rates,
clock offset, pipeline latency, queued samples and timing error. Null means invalid
or unavailable. Windows accompany playback resets. `timingStateChanged` includes compact output
clock summaries even when larger windows are trimmed. `playbackStarted` records the
fixed source anchor, local source-sample base and scheduled host start. Output-node
deltas classify timing confidence and estimate consumption rate, never acoustic delay.

Before omitting events to fit the 16 KB frame limit, serialization removes oldest
observations. Per-event and frame `observationOmissions` count removed observation
copies in that serialization; they are not cumulative run counters. Existing event
omission, retention and sequence-gap counters retain their meanings. Final statistics
use the same bounded serializer and Mac event deduplication.

Listener `buildInfo` identifies Debug/Release compilation, app version/build and OS.
`transportTimerDiagnostics` measures the 100 ms session timer, with gap thresholds
150/250/500 ms. Host reports include `senderDiagnostics.work` source/encode/handoff
wall times and `senderDiagnostics.delivery` send-slot lateness at transport processing,
with maxima, measurement counts and exceedance counts at 20/50/100 ms. Values are
aggregates, not packet traces. Receive gaps measure UDP callback delivery; they do
not independently establish Wi-Fi delay or permanent packet loss.

Protected-data events use the public iOS notifications and include the captured
`protectedDataAvailable` value; a will-become-unavailable notification may still
report true at receipt. Initial state is retained when idle. `streamStarted` carries
the latest known state, followed by `protectedDataStateAtStreamStart`, captured on
the main queue when the stream-start capture request is handled. Its timestamp is
that capture time, not an inferred lock time. These events neither detect exact
screen-off/wake times nor change audio/session behavior.

The Mac-only `markTestTransition` command accepts `marker`: `background`, `foreground`,
`lock`, `wakeLocked`, or `unlock`. Native receipt time is captured before queueing.
Active-run reports retain up to 256 `testMarkers` with UTC, monotonic and stream-relative
times and `kind: userReportedTransition`; `testMarkerRetentionOverflow` exposes loss.
Markers reset per run, do not increment audible interruption counts, and are separate
from the rolling human-readable log. No control-protocol messages are added.


Session errors are tracked by subsystem. Listener discovery faults are suppressed
while the host connection is ready, but remain available if that connection is lost;
current-browser ready/results clear discovery faults. Superseded browser callbacks
are ignored. TCP readiness clears connection waiting errors; successful advertised
hosting clears host discovery warnings, while a manual-only fallback retains them.
Audio-session readiness and playing renderer statistics clear only their respective
faults. Successful retry clears its own command error; unrelated commands do not.
Explicit stop-host/disconnect clears faults for the stopped subsystem. Reports'
`renderError` contains audio-session/renderer failures, not discovery/command errors.

### Policy and build provenance

Listener and host `buildInfo` include diagnostic policy version 3, Git revision (with
a dirty marker), and a SHA-256 fingerprint of native AudioCore source. Runner build
phases generate `SilentDiscoAudioBuild.json` into the app bundle; source files are not
modified. Missing bundle metadata is reported as unknown, including Swift package
tests. The opt-in `SDAudioLatencyProbe` launch setting or `SD_AUDIO_LATENCY_PROBE=1`
environment variable reproduces the old query cadence on the isolated control queue.
Its report flag must be false for acceptance. See AUDIO_TESTING.md for getter
signposts, field interpretation, physical acceptance and limitations.
