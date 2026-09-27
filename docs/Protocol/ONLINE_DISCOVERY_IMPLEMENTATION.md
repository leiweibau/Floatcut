# Floatcut Sync v2: cross-platform discovery and online-state implementation specification

Status: implementation specification and review findings, 2026-09-19. This document
does **not** change the v2 wire protocol. Implementations must continue to use
[`floatcut-sync-v2.md`](floatcut-sync-v2.md) and its shared fixtures as the wire
contract. Any wire-level change must first be agreed in `Floatcut-SRC` and
reflected in both platform implementations.

## Purpose and terminology

DNS-SD discovery, permission to start a **new** pairing, a persisted pairing,
and an authenticated online connection are separate states:

| State | Meaning | Source of truth |
| --- | --- | --- |
| Advertised | The local app publishes `_floatcutsync._tcp` and an SRV/TXT record. | Local listener and DNS-SD registration |
| Discovered | A remote DNS-SD service has a valid, compatible advertisement and a current endpoint. | Browser/resolve results, with expiry/removal |
| Paired | A pin and peer record were persisted after two-sided confirmation. | Per-user peer store |
| Online | A current connection to an enabled, paired peer reached `Trusted` with the stored certificate pin. | Live connection state, not DNS-SD |

There is no `online` TXT key. The TXT value `pair=1` permits new pairing
requests; `pair=0` forbids only those requests. A `pair=0` host can still be
discovered and remain online for previously paired peers. An advertised or
discovered host must not be shown as **Online** until the authenticated channel
is trusted. Conversely, a temporary DNS-SD loss must not by itself mark an
intact trusted channel offline.

## Advertisement and listener lifecycle

1. When sync is enabled and the local identity is available, start a listening
   endpoint and register `_floatcutsync._tcp`. When sync is disabled, shut down
   the listener/browser and remove the local registration. Do not require or
   attempt to restart the operating system's mDNS daemon.
2. Publish the v2 TXT keys `id`, `pv`, `platform`, `caps`, and `pair` in lower
   case. Use the canonical local device ID, `pv=2`, the current sorted v2
   capabilities, and `pair=0|1`. The SRV record supplies the **actual** listener
   port; never derive a port from the instance name or TXT data. Do not publish
   clipboard data, pairing codes, keys, certificate material, or an online flag.
3. Derive `pair` from the new-pairing preference and the maximum paired-peer
   count. Keep the service advertised when `pair=0` so trusted peers and
   resumable pending handshakes can still connect.
4. Refresh the TXT/service announcement after every persisted state change
   affecting `pair`: enabling/disabling new requests, completing a pairing,
   **local or remote** unpair/revocation, and any peer-store repair that changes
   the count. Refresh the instance name after a device-name change. Do the
   refresh after the store transaction succeeds, not before it. A transition
   from ten paired peers to nine must change `pair=0` back to `pair=1` when
   new requests are allowed.
5. Treat listener registration failure as a separate health failure from
   browser failure. Report it and retry with bounded backoff/jitter while sync
   remains enabled. Do not leave a permanently failed listener behind an
   apparently healthy sync toggle. Avoid concurrent replacement listeners or
   stale callbacks from an older listener generation.
6. A user-requested Bonjour/mDNS restart re-creates only the app's browser and
   service registration. It must preserve identity, peer pins, pending
   pairings, revocations, clipboard history, and established peer connections
   unless the platform network API makes an existing connection fail. Such a
   failure follows the normal reconnect path. Repeated clicks must be safe.

## Discovery lifecycle

1. Validate TXT keys case-insensitively as specified by v2, reject duplicate
   keys after ASCII case-folding, and validate values without case-folding.
   Require a canonical peer ID different from the local ID, `pv=2`, valid
   `platform`, `pair=0|1`, and compatible capabilities. Normalize DNS names
   only for lookup/deduplication; retain their original spelling for display.
2. Track discovery by device ID while retaining the current resolved endpoint
   or endpoint set. Multiple interfaces/results for one device must not create
   duplicate UI rows or parallel connection attempts. Remove or expire a
   service according to the platform's DNS-SD API; do not retain a stale port
   after an SRV update. A browser restart invalidates callbacks from its old
   generation and clears stale results before accepting the new snapshot.
3. A browser failure must be visible in diagnostics and trigger bounded
   recovery while sync stays enabled. Recovering the browser must not reset
   trust data or tear down a still-healthy trusted connection.
4. The current publisher emits exactly the three v2 capabilities. Receiver
   handling of **additional** sorted capabilities requires a shared decision:
   the [normative text](floatcut-sync-v2.md) calls the three values mandatory,
   whereas [`CONFORMANCE_V2.md`](CONFORMANCE_V2.md) says “exact sorted v2
   `caps` value.” Until those documents are reconciled in `Floatcut-SRC`, do
   not change one platform's acceptance rule alone. Cross-platform acceptance
   tests must at least cover the exact current value and a missing mandatory
   capability; a valid superset is an explicit open test case.

## Paired connection and Online lifecycle

1. For an established normal channel, the peer with the smaller canonical
   device UUID initiates; the larger listens. Initial pairing and revocation
   retain their protocol-defined direction rules. A `pair=0` announcement
   must not block an already paired, enabled peer.
2. Reserve an outgoing attempt by **target device ID before** TCP/TLS starts.
   Browser updates, retries, and user actions must not start a second attempt
   for that target while one is preparing, waiting, or awaiting HELLO. Track
   the intended peer ID separately from the ID learned through HELLO.
3. On every outgoing failure, timeout, cancellation, or TLS/pin rejection,
   release that reservation. If failure occurs **before HELLO**, the intended
   peer ID must still be available to decide whether to retry. A retry must
   not depend on a fresh Bonjour event when the peer remains discovered.
4. For normal trusted-channel reconnects, retry only while sync is enabled,
   the peer remains discovered and enabled,
   the pin is still valid, and the local device is responsible for dialing.
   Use the v2 reconnect delays (approximately 1, 2, 4, 8, 16, then at most
   30 seconds, with jitter). Cancel or invalidate pending retry timers after
   disable, unpair, identity change, discovery loss, or a successful trusted
   connection. An endpoint change should cause the next attempt to use the
   current SRV endpoint. Pending-pairing recovery and revocation delivery use
   the separate eligibility rules below; neither requires a paired record.
5. Set **Online** only after the connection enters `Trusted` and its identity
   matches the stored pin. Clear it when that trusted connection ends or is
   disabled/revoked. A transient transport `waiting` state may remain online
   only while the same connection is recoverable and the protocol's receive
   liveness bound has not expired. Keepalive after 30 seconds idle and loss
   after 90 seconds without received data are defined by v2; the UI can
   therefore lag a physical outage by that bound plus the scheduling tolerance
   specified below. Do not present
   “last seen” as a live heartbeat timestamp unless it is actually updated
   by authenticated traffic.
6. Paired records are per-user persistent trust, not online presence. Neither
   an advertisement nor a peer record authorizes clipboard transfer before
   `Trusted`. V2's no-offline-queue/no-backfill rule remains unchanged.

## Detailed cross-platform implementation requirements

The following requirements are normative for implementing this lifecycle
specification. MUST and MUST NOT indicate acceptance requirements. They refine
local scheduling and state management; they introduce no messages, TXT keys,
trust shortcuts, or changes to v2 framing. Where the wire contract forbids an
operation, these requirements do not authorize it. The capability-superset
question above remains open; agents MUST retain the exact current capability
list until the shared contract is reconciled.

### R1. Explicit attempt purpose and retry eligibility

Each attempt MUST retain `engineEpoch`, `attemptID`, `targetDeviceID`,
`purpose`, selected endpoint key, expected pin (if known), and its establishment
deadline before any asynchronous connection work begins. `purpose` is one of
`trusted`, `pairingResume`, `revocation`, or `newPairing`. DNS-SD identity is
only a routing hint: the authenticated certificate/SAN and HELLO device ID
MUST match the target before the attempt can succeed.

All automatic attempts require enabled local sync, an available local identity,
and at least one currently discovered compatible endpoint. Additional rules:

| Purpose | Eligible initiator and record | Success | Stop condition |
| --- | --- | --- | --- |
| `trusted` | Enabled paired record and valid stored pin; smaller canonical UUID dials. | Authenticated channel becomes `Trusted`. | Disable, unpair, identity change, security failure, or discovery loss. |
| `pairingResume` | Unexpired pending transcript with pinned certificate; the original pairing initiator dials, regardless of UUID ordering or `pair=0`. An explicitly disabled paired record blocks this recovery. | Matching transcript completes/resumes according to v2. | Expiry, explicit rejection/cancellation, disable, identity change, security failure, or discovery loss. |
| `revocation` | Unacknowledged local tombstone and its original certificate pin; the revoking side dials regardless of UUID ordering, peer enablement, or `pair=0`. | Authenticated matching `UNPAIR_ACK` is persisted. | ACK, explicit tombstone removal/replacement by verified re-pairing, local sync disable, identity change, security failure, or discovery loss. |
| `newPairing` | Explicit user action for an eligible discovered host advertising `pair=1`. | A resumable transcript is persisted, or pairing completes. | Failure before a resumable transcript exists requires a new user action; do not automatically create repeated pairing prompts. |

Discovery loss suspends retries; it does not delete pending records or
tombstones. On rediscovery, re-evaluate eligibility and the existing retry
deadline. Revocation has priority over resume, which has priority over normal
sync. Records conflicting with a tombstone MUST NOT authorize clipboard data.
A revocation connection MUST never enter clipboard-enabled `Trusted`.

A transport failure MUST NOT create a new request ID or extend the pending
transcript's expiry. Preserve the stored expiry across retries. A newly
completed transcript may receive its v2 ten-minute completion retention window
once; duplicate completion/resume messages MUST NOT renew that window.
Resuming a transcript MUST NOT manufacture user confirmation. Records without
a recoverable original-initiator role MUST NOT guess a role from UUID order:
report that explicit re-pairing is needed. Existing v2 transcript and rejection
rules continue to apply.

Connection establishment, including TLS and HELLO, has a 15-second deadline
from attempt start. After sending `UNPAIR`, allow 15 seconds for its ACK, then
close and retry the same tombstone with backoff. This does not expire the
tombstone. A transport disconnect or missing ACK is retryable; an explicit
pairing rejection is terminal for that request. A certificate-pin/identity
mismatch or authenticated protocol incompatibility suspends automatic retries
for that attempt purpose and peer until explicit user remediation or a local
configuration change resolves the cause. TXT changes alone MUST NOT clear a
security suspension or replace a stored pin.

### R2. Existing connection, duplicates, and replacement

Maintain one authoritative connection slot per device, with an immutable
connection ID. Pre-HELLO outgoing reservations also occupy that slot. Incoming
connections are bounded candidates until authenticated HELLO identifies their
peer; they MUST NOT appear Online during this phase. Allow at most 32 incoming
pre-HELLO candidates per engine and immediately close excess candidates. All
candidates retain the 15-second establishment deadline and existing rate limits.

When an authenticated candidate meets an occupied slot, apply these rules in
order on the serialized state executor:

1. Reject a candidate that fails identity/pin, purpose, enablement, or v2
   direction checks. A new unauthenticated advertisement never evicts a channel.
2. If the incumbent is closing, ended, or past its receive-liveness deadline,
   retire it before assigning the otherwise eligible candidate. Retirement
   immediately invalidates its work and clears its ownership of the slot.
3. Otherwise keep the incumbent and close the candidate. In particular,
   `waiting` alone does not prove that the incumbent is dead. A healthy pairing
   channel may retain its initial user-selected direction under v2.
4. An old connection's completion, cancellation, or retry callback may clear a
   slot only if both its engine epoch and connection/attempt ID still own that
   slot. It MUST NOT clear or publish Offline for a replacement connection.

This deliberately allows a fast peer restart to wait for the old channel's
90-second receive deadline. No takeover protocol is added. The dialer retries
with backoff after duplicate rejection, even if no DNS-SD event occurs.
Once the old deadline expires, the next eligible attempt can take the slot.
The implementation MUST NOT oscillate by replacing healthy channels whenever
a candidate arrives. A user revocation invalidates clipboard authorization
immediately and may reuse the existing authenticated transport for `UNPAIR`.

### R3. One scheduler and backoff that discovery cannot bypass

All discovery, timer, activation, and failure events MUST feed a single
serialized per-peer scheduling decision. Persist in memory one failure counter,
one `nextAttemptAt`, one attempt reservation, and at most one armed retry timer
per peer. Timer callbacks carry the engine epoch and scheduler generation.

For consecutive failed automatic attempts numbered `n = 1, 2, ...`, calculate:

```text
baseSeconds = min(2^(min(n, 6) - 1), 30)
delaySeconds = min(30, baseSeconds * uniformRandom(0.8, 1.2))
nextAttemptAt = monotonicFailureTime + delaySeconds
```

There is no backoff before the first eligible attempt. The scheduler MUST NOT
start an attempt before `nextAttemptAt`, while a slot/reservation is occupied,
or after eligibility was revoked. Repeated discovery announcements, TXT/name
changes, endpoint updates, and manual Bonjour restart MUST NOT reset the
counter/deadline or arm additional timers. A successful purpose-specific
exchange resets the counter and invalidates its timer. Explicit new pairing or
new local revocation is a new user operation; it may start immediately after
retiring conflicting work. Toggle spam MUST NOT accumulate callbacks.

When discovery vanishes, invalidate the timer but retain the in-memory counter
and deadline. Rediscovery before that deadline waits; rediscovery after it may
start immediately. Re-read current endpoint, records, epoch, suspension state,
and eligibility at timer execution, not only when the timer is created.
Automatic retry state need not survive process restart. Listener/browser
recovery uses its own backoff and generation, separate from peer attempts.

### R4. Precise liveness clocks and suspend/resume behavior

Runtime deadlines MUST use a monotonic elapsed-time source, never wall-clock
`Date`/UTC arithmetic. Wire timestamps, persisted expiry timestamps, and human
log timestamps remain Unix time as required by v2. Do not serialize monotonic
ticks across process restarts. Pending expiry within a process must also be
bounded by the remaining duration captured when its persisted record is loaded;
moving the wall clock backwards must not extend that runtime duration.

After transport readiness, initialize receive/send activity times. Any nonempty
decrypted transport receive updates receive activity; empty callbacks, DNS-SD
events, outgoing data, and UI activity do not. Invalid wire data is still
rejected under v2 and cannot authorize a channel. This preserves v2's
"without received data" rule rather than inventing a required PONG exchange.
Successfully processed outgoing transport data updates send activity.

Schedule PING at `lastSent + 30s` and close at `lastReceived + 90s` using
reschedulable deadlines. Timer callbacks MUST recheck current times and epoch.
On a normally scheduled, awake system, network-state transitions must occur
within one second after the deadline and the Online UI must reflect them within
one further second. A scheduler/OS stall is logged as deadline lateness; no
implementation may claim a hard real-time guarantee during suspension/stall.
The old ten-second polling interval does not meet this acceptance target.

Use a monotonic source that includes system sleep, or explicitly reconcile
suspend/resume so sleep time cannot preserve a stale Online claim. If the
platform cannot determine elapsed sleep reliably, retire pre-suspend channels
on resume. Otherwise recheck deadlines before publishing their Online status;
expired channels close and follow normal retry. Large wall-clock changes must
not cause premature or indefinitely postponed liveness timeouts.

### R5. Receive pressure and control-message progress

An event loop/network queue MUST NOT perform blocking image conversion, disk
I/O, or UI work. Bound clipboard work and preserve wire-order validation;
never scan past an incomplete frame for PING/PONG or reorder state-changing
messages. Do not create an unbounded second buffer to reach control traffic.

For this implementation profile, stop issuing new reads when queued plus
in-progress clipboard payload reaches 2 MiB or 128 messages. One already-issued
read/decode batch may exceed that threshold; the receive request itself must
be bounded to at most 64 KiB and each frame to the existing 1 MiB wire limit.
Retain existing v2 decoded-image limits separately. Resume reads as soon as
both queue counts are below their thresholds. Track the time the read pause
began independently of peer liveness.

A continuous local read pause MUST NOT exceed five seconds. If work has not
freed capacity by then, close with diagnostic reason `local_receive_overload`,
invalidate pending clip work, clean incomplete images, and apply normal retry.
Do not report this as a peer liveness timeout. This is a local reason, not a
new wire ERROR code. Unapplied clips may be lost under v2's existing no-replay
rule; never send an `applied` ACK for them. The five-second bound intentionally
prevents a local processing stall from silently consuming the whole heartbeat
window. It does not guarantee control-message delivery through an overloaded
TCP stream. Faster-than-five-second pauses must allow reading to resume and
existing control handling to progress without false Offline transitions.

### R6. Endpoint membership, fallback, and interface scope

Keep device identity separate from DNS-SD service membership. Identify each
service observation by normalized instance/type/domain plus interface scope.
Keep its current SRV target/port and resolved address candidates separately.
An address candidate key includes address family, address bytes, port, and
interface/scope ID. IPv6 link-local addresses MUST retain a usable scope ID;
reject an unscoped link-local candidate. Never treat a device name as a key.

A service removal/expiry removes only that observation and its candidates.
The logical device remains discovered while any valid observation exists.
Invalid replacement TXT removes that observation's old compatible candidates;
it must not leave them usable indefinitely. An SRV update replaces the old
port for that observation. An in-flight attempt using a removed/replaced
candidate is cancelled and goes through the scheduler; a healthy established
channel survives discovery changes. Duplicate IDs with different endpoints
are routing candidates, not evidence that their certificates can be trusted.

Prefer the most recently successful candidate if it is still advertised and
has not failed in the current candidate cycle. Order other candidates by the
canonical candidate key (family, address bytes, port, interface); retain stable
ordering across unchanged browse snapshots. Attempt one candidate per retry;
on transport failure select the next untried candidate at the next backoff
deadline. After all candidates fail, start a new cycle. Do not retry one failed
preferred candidate forever while alternatives exist. Security failures follow
R1 and do not weaken pin checks on another route.

An OS-managed service endpoint may resolve/race addresses internally, provided
it preserves scope and implements address fallback within the 15-second
establishment bound. Treat those internal address attempts as one logical
attempt. If this cannot be demonstrated by tests, manage resolved candidates
explicitly. Interface IDs are local opaque values; platforms need not select
the same physical route, but must satisfy the same fallback and trust rules.

### R7. Engine epochs, UI snapshots, and error precedence

Increment an engine epoch on sync disable, engine replacement, and local
identity reset. Every asynchronous network result, timer, worker completion,
and UI update carries that epoch. On the destination executor (including the
UI thread), discard events whose epoch is no longer current. Bonjour restart
additionally increments its discovery generation without invalidating healthy
connections. Disabling sync synchronously invalidates publication authority
before asynchronous transport shutdown begins.

Publish immutable UI snapshots with epoch and increasing revision. The UI
accepts only its current epoch and revisions newer than the last accepted one.
Online IDs are derived from current, authorized, nonexpired `Trusted` slots;
they are not incrementally maintained by unrelated callbacks. A disabled or
revoked peer disappears from the Online set in the same logical transition as
its authorization is removed, without waiting for the OS cancellation callback.

Maintain separate listener health, browser health, identity/security state,
and per-peer state. In a single summary label, use this precedence:
disabled > identity unavailable > security warning > listener failed/waiting >
browser failed/waiting > starting > available-device count. Within a level use
the latest revision. Peer success must not clear listener/browser failures;
only recovery of that component clears its error. A component's `ready` event
clears its own waiting/failure state. Peer counts never establish advertisement
health. A listener is advertised only after service registration is confirmed
by the platform API, not merely because a listener object exists.

## macOS implementation mapping

This section is an implementation task map for the Floatcut app, not a claim
that the changes below are already present. Symbol names refer to the reviewed
`Sync/FloatcutSyncCoordinator.swift` and `Sync/FloatcutSyncWork.swift` sources.
Other platforms MUST implement R1–R7 using their own execution/network APIs.

| Requirement | macOS change location and required result |
| --- | --- |
| R1 | Extend `open`, `adopt`, and `FloatcutPeerConnection` initialization with target identity, purpose, epoch, and attempt ID. Replace the paired-record-only guard in `scheduleReconnect` with the purpose eligibility table. Keep the same pending request/tombstone across transport failures; make `persistPending` expiry stable. Arm a revocation ACK deadline. |
| R2 | Replace the nil-only check in `didIdentify` with slot ownership and the ordered incumbent rules. `cancel`, `finish`, and `connectionEnded` must be idempotent and compare owner IDs before publishing/removing state. Maintain a bounded pre-HELLO incoming pool and enforce establishment deadlines; use a local limit of 32 candidates, immediately cancelling excess candidates. |
| R3 | Route `handleBrowseResults`, `peerActivationChanged`, `connectionEnded`, and retry timers through one scheduler on the existing serial network queue. Store a cancellable timer or generation token plus `nextAttemptAt`; do not call `open` directly from each browse update. |
| R4 | Replace `Date` activity deltas in `FloatcutPeerConnection` with an injectable continuous elapsed-time clock. Replace the repeating ten-second keepalive check with deadlines. Add resume reconciliation and deterministic clock-driven tests without changing wire `sent_at_ms`. |
| R5 | Extend `FloatcutSyncOrderedInbox` with explicit pause/progress signals and the five-second overload deadline. Keep image work off the network queue. On overload, invalidate work via existing lifetime tokens and image cleanup, then log the distinct local cause. |
| R6 | Replace the last-result-wins `newPeers[deviceID]` assignment with a per-device collection of observations/candidates. Preserve the interface carried by Bonjour endpoints. Verify `NWConnection` service resolution fallback with IPv4/IPv6 tests; add explicit selection if it cannot satisfy R6. |
| R7 | Pass engine epoch and snapshot revision through `updateDiscovery`, `updateOnline`, and `showNetworkError`, and check them inside the main-queue closure. Separate component health from `statusText`. Use listener service-registration updates for advertisement health; update `publishOnline` on authorization changes. |

Keep existing unrelated worktree changes intact. Implement in this order:
epoch/slot ownership and injectable clock; purpose-aware scheduling; endpoint
membership/fallback; liveness/backpressure; UI health presentation. Then run
the existing protocol/engine tests and the additional lifecycle tests below.
Fix the already identified missing advertisement refresh after remote revocation
as part of listener/TXT lifecycle work. A build or passing codec tests alone
does not establish conformance to these lifecycle requirements.

## Diagnostics and user-facing state

- Distinguish at least: sync disabled, identity unavailable, advertising,
  listener failed, browsing, browser failed, discovered but connecting,
  paired but offline, and trusted/online. A count of discovered services is
  not evidence that this device is advertising or that a paired channel works.
- Log redacted events for listener ready/failure, browser ready/failure,
  advertisement and TXT policy changes, endpoint changes/removals, outgoing
  attempt start/end, pre-HELLO failure, retry scheduling/cancellation, trust,
  and Online transitions. A run ID, event timestamp, direction, attempt number,
  and short peer-ID prefix are useful; clip contents, full keys, nonces,
  comparison codes, and certificates are not.
- The manual restart control must state that it restarts **Floatcut's**
  Bonjour/mDNS components, not the system service, and must not imply that
  pairing data will be deleted. Disable it when local sync is off.

## Cross-platform acceptance matrix

Run these cases in both directions between macOS and the independent Windows
implementation, and repeat the network-sensitive cases with the Python SRC
where it supports them. A protocol/codec unit test alone is insufficient.

| Case | Required observation |
| --- | --- |
| Sync off/on | Service disappears/appears; SRV port reaches the current listener; TXT matches v2. |
| `pair=1` → `pair=0` → `pair=1` | Announcement updates; an existing trusted peer stays connected and can transfer. |
| Ten peers → nine via local **and remote** revocation | Pairing policy and announced TXT return to `pair=1` when allowed. |
| Paired host advertised but TLS unavailable before HELLO | Shows Offline/connecting, retries with backoff without any new DNS-SD event, then reaches Online after recovery. |
| Repeated DNS-SD updates or multi-interface results | One logical device and at most one outgoing attempt per target. |
| Trusted connection lost; announcement stays visible | Online clears by the liveness bound, then reconnects with backoff and the current endpoint. |
| Announcement disappears but trusted channel survives | Existing channel remains Online; reconnect waits for rediscovery if that channel later fails. |
| Browser or listener fails | Error is visible and app-owned component recovers without identity/pairing reset. |
| Manual Bonjour restart during an active trusted channel | No trust-data loss; existing connection stays usable or reconnects normally if its transport drops. |
| Sleep/wake, WLAN change, IPv4/IPv6 and firewall/local-network permission changes | No permanent Offline state while a compatible paired host remains reachable. |

For each test capture redacted logs on both clients and a DNS-SD browse/resolve
trace. Check service presence, TXT and SRV separately from the trusted-channel
Online indicator. Do not declare this matrix passed from a single snapshot or
loopback test.

### Deterministic regression cases for R1–R7

Use an injected clock and random source for scheduler tests, a controllable
transport, and deliberately delayed callbacks. Set the jitter multiplier to
`1.0` unless the case explicitly tests its range. Advance virtual time instead
of waiting in real time. Execute pairing/resume/revocation cases with both UUID
orderings. In these tests "no new discovery event" means the last compatible
snapshot remains valid; it does not mean discovery has been lost.

| ID | Setup and event sequence | Required assertions |
| --- | --- | --- |
| T01 / R1 | Pending transcript exists, no paired record; original initiator has the larger UUID. Break transport before HELLO, keep discovery unchanged and `pair=0`. | Retry after the scheduled delay with the same target, pin, request ID, transcript, and expiry. No repeated confirmation prompt for a confirmation already persisted. Completion follows v2. |
| T02 / R1 | Remove the paired record through local unpair; drop the first `UNPAIR_ACK`. | Connection closes 15 seconds after sending UNPAIR; retry uses the same revocation ID and pin without needing a paired record. Persisted matching ACK stops retries. Tombstone remains stored. |
| T03 / R1 | Expire a pending record, reject its request explicitly, or remove its tombstone; then deliver an old retry callback. | No connection opens. These are separate test runs; expiry and terminal rejection are not retried. A transport failure never extends expiry. |
| T04 / R1 | Present a different certificate for a known target; repeat TXT updates afterward. | No Trusted/Online transition or clipboard authorization; security suspension remains, and TXT updates do not trigger repeated automatic attempts. |
| T05 / R2 | Incumbent received data at t=0; restarted peer presents a valid candidate at t=10 and again after t=90. | First candidate cannot displace the unexpired incumbent. After expiry the eligible candidate can own the slot. Delivering the old connection's end event afterward leaves the replacement Online. |
| T06 / R2 | Deliver duplicate incoming/outgoing HELLO callbacks and duplicate cancellation callbacks in different orders. | At most one authoritative slot and one clipboard-authorized channel remain; wrong-direction candidates are rejected according to v2. A healthy incumbent is not repeatedly replaced. |
| T07 / R3 | Automatic attempts fail immediately at t=0, 1, 3, 7, 15, 31. Flood 100 browse updates between each pair of attempts. | Attempts start only at t=0, 1, 3, 7, 15, 31, 61; one retry timer/reservation per peer. With real jitter, each failure-to-next-attempt interval lies in the formula's range and never exceeds 30 seconds excluding execution delay. |
| T08 / R3 | A failure schedules retry at t=4. Remove discovery at t=1; restore at t=2, then repeat with restoration at t=5. | First run waits until t=4; second may try at t=5. Old invalidated timers do not open extra connections. Manual Bonjour restart does not reset the deadline. |
| T09 / R4 | Last received data at elapsed t=0, then no further data. Jump wall time forwards/backwards by one hour. | Loss transition occurs at elapsed t=90 (within one-second scheduling tolerance), UI within one further second; wall-clock jumps have no effect. Successful traffic at t=89 moves the receive deadline to t=179. |
| T10 / R4 | Suspend for 120 seconds with a previously trusted connection, then resume. | Reconciliation retires the expired channel before publishing it Online again. If elapsed sleep is unavailable, retire conservatively. Reconnect requires the normal authenticated handshake. |
| T11 / R5 | Fill clipboard work to its high-water mark; pause processing for two seconds, with control traffic waiting. Repeat with processing blocked for six seconds. | Short pause resumes bounded reads/control processing without a false loss. Long pause closes at five seconds with `local_receive_overload`, never `peer_timeout`; no false applied ACK, unbounded buffering, or retained incomplete image. |
| T12 / R6 | Same device appears on two interfaces; candidate A fails, B is reachable. Remove only A's service observation, then change B's SRV port. | One UI row persists; scheduler falls back to B and uses its current port. Removing A does not remove B. Repeat with IPv6 link-local scope and mixed IPv4/IPv6. |
| T13 / R6 | Replace one observation's TXT with invalid data while a second valid observation remains; repeat without the second observation. | Only the invalid observation loses eligibility. The first run remains discovered; the second stops retries. Existing healthy Trusted transport is not evicted solely by TXT change. |
| T14 / R7 | Delay old engine's Online/error/discovery UI closures; disable then enable sync with a new epoch. Deliver old closures after the new snapshot. | No old Online IDs, peer counts, or errors overwrite current state. Lower/equal snapshot revisions are ignored. Disable/unpair removes authorization before transport completion. |
| T15 / R7 | Listener fails while browser still discovers peers and an existing peer remains connected. Deliver peer-success and count updates, then listener recovery. | Listener error stays visible until that component recovers. The surviving peer may remain Online independently. Advertisement becomes healthy only after registration confirmation. |
| T16 / R2 | Open 33 incoming connections without HELLO and keep the accepted ones stalled. | At most 32 pre-HELLO candidates exist, excess closes immediately, and remaining stalled candidates expire at their establishment deadlines. No candidate appears Online. |

Unit tests establish ordering, bounds, and cancellation behavior. Complement
them with actual macOS/Windows (and supported SRC) runs for T01, T02, T05,
T10–T12, and T15. Record operating systems, client commits, selected interfaces,
clock/lateness measurements, and outcomes. An unsupported SRC scenario is
reported as not tested rather than passed. The 15-second establishment/ACK,
five-second overload, and UI scheduling targets are explicit implementation
profile decisions introduced here; they are not claims about measured current
behavior or new wire-protocol fields.

## Review findings that motivated this specification

- In macOS `FloatcutSyncCoordinator.swift`, `connectionsByDeviceID` is filled
  only after HELLO. A pre-HELLO outgoing failure can therefore end without a
  peer ID for `scheduleReconnect`, while repeated browse updates can start
  parallel attempts. The current listener/browser `.failed` handlers report
  errors but do not automatically recover.
- macOS refreshes `pair` after a local unpair and a completed pairing, but
  `acceptRemoteRevocation` currently changes the peer count without refreshing
  the announcement. This is visible when leaving the ten-peer limit.
- A live DNS-SD check on 2026-09-19 found both the macOS Floatcut and a
  Windows v2 service with resolvable SRV records, the expected capability
  list, and `pair=1`. No removal/reannouncement occurred during a 20-second
  observation. That establishes only advertisement visibility, **not**
  pairing, TLS reachability, or reconnect stability. The local macOS v2 peer
  store was empty, so a live paired-Online test was not possible.

Implementation priority: first make attempt tracking and pre-HELLO retry
deterministic; then keep listener/browser advertisement and recovery healthy;
then resolve the capability-checklist ambiguity and pass the cross-platform
acceptance matrix. No code change is implied by this document alone.
