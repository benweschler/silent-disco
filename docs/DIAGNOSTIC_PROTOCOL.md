# Diagnostics protocol v1

This protocol is a development harness, not the eventual audio protocol. Both
projects contain identical Swift core/bridge sources, protocol docs, and packet
fixtures. Keep those copies in sync when changing the protocol. No shared-path
runtime dependency or third-party networking package is required.

## Discovery and control

The Mac advertises `_silentdisco._tcp` in the local Bonjour domain with TXT
`version=1` and display name `Silent Disco Diagnostics` (Bonjour may rename a
collision). TCP and UDP use OS-assigned ports. NWParameters disables peer-to-peer
links; the acceptance procedure additionally unplugs USB and disables cellular.

TCP is UTF-8 newline-delimited JSON. Maximum 16,384 bytes per message excluding
the newline. Split/coalesced reads are supported. Every message needs a string
`type`. Invalid JSON, non-object messages, or oversize frames close the session.
Unknown types are ignored. One control client is accepted; others receive
`error` with a busy message before closure. Traffic is unencrypted and intended
for the password-protected test LAN; session tokens are correlation/registration
credentials, not a substitute for transport security in a future product.

Handshake:

1. Phone: `hello` with integer `version=1` and `device` metadata.
2. Mac: `welcome` with `version`, `session` UUID, base64 16-byte random `token`,
   `udpPort`, and `device` metadata. A different version is rejected.
3. Phone resolves UDP using the actual TCP remote host, registers via packet kind
   0, and retries registration each second until acknowledged.
4. Mac accepts a valid token from the TCP peer IP and replies with packet kind 1.
5. Phone sends TCP `udpReady`. Both sides now expose readiness. This extra control
   acknowledgement prevents a start request overtaking the UDP handshake.

Messages during a session:

| Type | Direction / fields |
|---|---|
| `heartbeat` | Both directions, every second |
| `requestStart` | Phone → Mac: `profile`, `notes` (max 2,000 chars), `offlineConfirmed` |
| `prepare` | Mac → phone: `profile`, decimal-string `run` |
| `prepared` | Phone → Mac: `run` |
| `begun` | Mac → phone: `run`; starts phone timing |
| `stats` | Phone → Mac every second: `run`, aggregate `stats` |
| `requestStop` | Phone → Mac |
| `stopping` | Mac → phone: `run`, measured/clamped `elapsed` |
| `finalRequest` | Mac → phone after two seconds of drain: `run` |
| `finalStats` | Phone → Mac: `run`, final `stats` |
| `report` | Mac → phone: structured `report` |

A lost control connection or five seconds without incoming control traffic
interrupts the run. Initial UDP readiness also has a ten-second deadline. The
phone retries the previously selected endpoint after 1, 2, 4, then 5 seconds,
capped at 5 seconds; it never restarts tests automatically.

## UDP packet layout

Every datagram is exactly 400 bytes. All integers are unsigned and big-endian.

| Offset | Bytes | Field |
|---|---:|---|
| 0 | 4 | ASCII `SDD1` |
| 4 | 1 | Version: `1` |
| 5 | 1 | Kind: 0 register, 1 ack, 2 data, 3 echo |
| 6 | 2 | Stream ID (0–2) |
| 8 | 16 | Random session token |
| 24 | 8 | Nonzero run ID for data/echo |
| 32 | 8 | Sequence, global within the run |
| 40 | 8 | Mac monotonic send time in nanoseconds |
| 48 | 352 | Deterministic `0xa5` padding |

Registration/ack have zero stream/run/sequence/timestamp. Data sequence increments
only for attempted sends, not skipped scheduler slots. Malformed datagrams,
wrong tokens, inactive run IDs, out-of-range streams, and excessive sequences
are ignored. The run cap bounds packets to fewer than 100,000.

Phone echoes each unique accepted data packet, changing only kind to 3. Duplicate
arrivals are counted but not echoed again, so echo submission counts remain
consistent with unique upstream delivery/loss. The Mac only accepts echoes whose
sequence and timestamp match a packet it attempted to send.

## Profiles and timing

| Profile ID | Duration | Streams | Datagram interval per stream |
|---|---:|---:|---:|
| `connectivity` | 30 s | 1 | 200 ms |
| `baseline` | 600 s | 1 | 20 ms |
| `threeChannel` | 600 s | 3 | 20 ms |

No client-provided duration is accepted. Native profiles and the sender cap limit
all traffic runs to 600 seconds. Final exchange can add up to five seconds without
extending traffic generation. Each direction of baseline carries 160 kbps of UDP
payload; the three-channel preview carries 480 kbps. These figures include the
diagnostic header and exclude UDP/IP/Wi-Fi overhead.

The Mac schedules batches on a serial queue with monotonic deadlines. If late,
it counts skipped slots and sends only the current batch, never a catch-up burst.
The three stream packets in a batch are deliberately adjacent; interarrival
variation/gaps are measured per stream to avoid treating those as timing errors.

## Counters and reports

`submitted` counts successful local send completions, not delivery acknowledgments.
`unique`, `duplicates`, and `reordered` describe received packets; reordering is
relative to the highest sequence observed. `skippedSendSlots` is distinct from
network loss. `sendErrors` counts failed local sends.

After the drain:

- Downstream missing = host submitted − phone unique received, clamped at zero.
- Upstream missing = phone echoes submitted − host unique echoes, clamped at zero.
- RTT uses echoed Mac timestamps and the same Mac monotonic clock. No one-way
  latency or clock offset is inferred.
- `meanInterarrivalVariationMs` is mean absolute difference between per-stream
  receive intervals and the target interval; `maxGapMs` is the longest observed
  per-stream interval. Neither is an audio jitter-buffer measurement.
- Throughput uses actual run elapsed time, excluding the drain.

Complete reports contain protocol/app/OS metadata, session/run IDs, endpoint and
interface addresses, profile/duration, start/end dates, host/phone metrics,
directional missing counts, run status/reason, `completeCounters`, `networkGate`,
user-confirmed offline setup, notes, and recent events. Tokens/passwords are never
included. Incomplete reports preserve available counters and are marked incomplete;
directional missing counts are null until final counters are available.

`networkGate=pass` requires a normally completed run, final counters, nonzero
traffic, loss under 0.1% in both directions, p95 RTT under 50 ms, receive gaps no
more than 250 ms, and no send errors on either device. It is a synthetic network gate, not
proof of offline configuration or audio viability. The 10-minute baseline report
is the required step 1 acceptance artifact.

## Flutter bridge

Method channel `silent_disco/diagnostics`: `snapshot`, `startHost`, `stopHost`,
`browse`, `stopBrowse`, `connect` (discovery `id` or numeric `host`/`port`),
`disconnect`, `startTest` (`profile`, `notes`, `offlineConfirmed`), `stopTest`,
`getReport`, and macOS-only `exportReport` (save dialog).

Event channel `silent_disco/diagnostics/events` sends aggregate snapshots on state
changes and once per second: `status`, `phase`, `ready`, `hosting`, `services`,
`addresses`, ports, endpoint, elapsed/duration/profile, `active`, metrics,
remote metrics, events, error, and optional latest report. Packets never cross
this bridge. Background/foreground/sleep are internal native lifecycle commands.
