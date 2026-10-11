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

- `hello(version=1,name)` → `welcome(version=1,token,udpPort)`; token is 16 random UUID bytes in base64.
- Client resolves UDP against the actual TCP peer IP, sends registration each second until
  acknowledgment, then `ready`. Host validates the token and matching TCP peer IP.
- `listen(enabled)` toggles delivery for that listener. A late listener receives stream configuration.
- `clock(id,t1)` → `clockReply(id,t1,t2,t3)`; phone records t4 on receipt. Host-minus-phone offset
  is ((t2-t1)+(t3-t4))/2. Reject negative or >=250 ms RTT; retain up to 32 samples/30 seconds,
  use the median offset of the five lowest-RTT samples. Require four samples. Refresh every
  two seconds after startup; expire the estimate after ten seconds without a valid reply.
- `stream(generation,anchor,lead,lookahead,rate=48000,frames=960,channels=2,codec=opus,source)`.
  Anchor is the Mac monotonic presentation time for source sample zero. Lead is 0.5/0.75/1.0 seconds.
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
only approximately 100 ms of PCM is scheduled ahead of rendering.

Output scheduling subtracts AVAudioIONode.presentationLatency once. Reported AVAudioSession
outputLatency is diagnostic only and is not added again. Playback uses a bounded ±0.1%
varispeed correction. Above 50 ms estimated error, fade 20 ms and rejoin the current timeline.
Six consecutive missing frames use PLC (120 ms); fade the last frame and rebuffer.

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
sustained-error candidate transitions. These are additive schema-2/protocol-1 fields.
