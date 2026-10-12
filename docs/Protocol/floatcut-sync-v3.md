# Floatcut Sync Protocol v3 — implementation contract

Status: normative implementation target, 2026-10-11. The Python reference
runtime still implements v2. This document specifies v3; neither its presence
nor passing fixture tests constitutes a working or independently reviewed v3
implementation. Native and reference implementations MUST pass
[CONFORMANCE_V3.md](CONFORMANCE_V3.md) before claiming conformance.

The terms MUST, MUST NOT and MAY express requirements. This document takes
precedence over earlier versions for v3. The v2 text/image payload definitions
are inherited only where explicitly stated below. The file profile version is
1; its availability is represented by `file.transfer.v1`.

## 1. Scope and fixed limits

Files are explicit, point-to-point user actions addressed to one selected
paired device. They do not enter the clipboard, propagate to other peers, or
create an offline sending queue. A transfer contains one regular file, including
an empty file. Directories, symlink metadata, resource forks, alternate data
streams, extended attributes, permissions, executable flags and archive
extraction are outside this profile. An archive can be sent as an ordinary byte
stream. The receiver MUST NOT automatically open or execute a received file.

| Parameter | Required value |
| --- | --- |
| Persisted peers in the selected active protocol version | 32, including offline/disabled peers |
| Control JSON payload | 1 through 1,048,576 bytes |
| File-channel JSON prelude payload | 1 through 16,384 bytes |
| JSON depth | 8, counting the root container as level 1; scalar values do not add a container level |
| File size | 0 through 8,589,934,592 bytes (8 GiB) |
| Binary DATA bytes per record | 262,144, except the final record |
| Nonterminal transfers per peer | One outgoing and one incoming |
| Nonterminal transfers per engine | Four outgoing and four incoming |
| Incoming pre-HELLO/pre-OPEN candidates per engine | 32 total across both ALPN protocols |
| Receiver receipt capacity | 1,024 accepted transfers, including reserved receipt slots |
| Terminal receipt retention | 24 hours from terminal outcome; never renewed by queries |

Source preparation, offered, awaiting user decision, accepted, connecting, receiving and committing
all count as nonterminal. Quota reservation and release MUST be serialized and
released exactly once. Peer capacity counts device IDs, not connection count
or UI rows. A new pairing reserves capacity; completion checks capacity again.
Existing-peer completion does not allocate another peer place.

## 2. Discovery, versioning and capabilities

Use `_floatcutsync._tcp`, with lower-case TXT keys `id`, `pv`, `platform`,
`caps`, `pair`, and `pv=3`. Device IDs are canonical lower-case UUIDv4.
`platform` matches `[a-z0-9._-]{1,16}`. `pair` is exactly `0` or `1` and controls
only new pairing requests. SRV supplies the sole listener port.

DNS names use ASCII case-insensitive comparison with an optional trailing root
dot. TXT keys use ASCII case-insensitive matching; duplicate keys after that
matching invalidate the advertisement. Values remain case-sensitive. Resolved
IPv6 link-local candidates MUST retain their interface scope. Multiple service
instances/interfaces for one device are memberships of one logical device;
removing one does not remove remaining memberships. An invalid replacement
advertisement invalidates that membership's previous endpoint.

Capabilities are a sorted, unique list of at most 16 names matching
`[a-z][a-z0-9._-]{0,47}`. Sort using unsigned ASCII byte order. The required base
capabilities are `clip.image.jpeg`, `clip.image.png`, `clip.text.utf8`.
`file.transfer.v1` is optional for a general v3 peer, and REQUIRED for an
implementation claiming the file profile. It means both sending and receiving
the profile are implemented. A temporary receiving preference does not remove
the capability; an incoming offer is rejected with `disabled` instead.

Receivers accept valid capability supersets. Unknown capabilities are inert.
Capabilities used on a connection are the intersection of both authenticated
HELLO lists; no unknown feature is activated by an advertisement. DNS-SD caps
are a routing/display hint. HELLO is authoritative and MUST NOT be rejected
solely because the advertisement's earlier caps snapshot differs. A selected
target ID MUST match the TLS SAN and HELLO ID. TXT cannot replace a stored pin.

There is one selected active major version per engine. A v3 engine advertises
only `pv=3`, accepts only `v=3` control envelopes, and MUST NOT silently downgrade
to v2. Archived v1/v2 trust does not authorize v3 and does not consume a v3 peer
place. New v3 pairing is required; implementations MUST NOT automatically import
old pins into trusted v3 stores. Switching a legacy mode is an explicit local
operation that shuts down the previous engine first.

## 3. TLS and the two connection classes

Both classes use the same listener and SRV port, with full mutual TLS 1.3:

| ALPN | Purpose | First application message |
| --- | --- | --- |
| `floatcut-sync/3` | HELLO, pairing, clipboard and file control | HELLO in each direction |
| `floatcut-file/1` | One accepted transfer's binary bytes | Sender FILE_OPEN; receiver FILE_READY |

Negotiated ALPN MUST match exactly. Missing/unknown ALPN is rejected without
application traffic. Both classes prohibit TLS 0-RTT and session resumption;
each connection presents and validates the full certificate again. Certificates
are self-signed ECDSA P-256/SHA-256, subject equals issuer, with positive serial
number of at most 159 bits, a currently valid 3,650–3,654-day validity interval,
critical BasicConstraints `CA=false`, and critical KeyUsage with only
`digitalSignature` set. EKU is exactly `serverAuth` and `clientAuth`; SAN contains
exactly one URI `urn:floatcut:device:<canonical-device-id>` and no other names.
The self-signature MUST verify. Unknown critical extensions are rejected;
noncritical extensions are ignored. The certificate chain is one leaf.

Control connections may admit an initially unpaired certificate only for the
restricted pairing exchange. File connections MUST authenticate an existing
enabled v3 peer with its current full-DER SHA-256 pin, before processing OPEN.
There is no pairing or historical-tombstone exception on file connections.

The lower UUID normally dials control; user-initiated pairing and its original
initiator's pending recovery are exceptions. The file sender always dials the
receiver, regardless of UUID order. It uses the current authenticated peer's
compatible SRV endpoint set and same listener port. No file message contains an
arbitrary host, URL, port or remote filesystem path. Endpoint fallback is bound
to the expected target ID and pin; a failed untrusted routing candidate does
not by itself replace the pin or permanently disable other legitimate routes.

Allow one authoritative control connection per device. An incoming pinned
noncanonical candidate remains `Restricted` until its first post-HELLO message
classifies it as a valid pending resume or historic revocation. It MUST NOT
receive clipboard/file permission by pin alone. Missing classification by the
establishment deadline closes it. A healthy incumbent wins over a duplicate;
callbacks can alter a slot only while their engine epoch/connection ID own it.

## 4. Common encoding, HELLO and control binding

Control and file preludes use a four-byte unsigned big-endian JSON byte length,
then exactly those bytes, strict UTF-8, no compression or line delimiter.
Reject duplicate keys, noninteger/exponent number syntax, NaN/infinity, lone
Unicode surrogates and excess container depth before dispatch. UUID text is
canonical lower-case UUIDv4; UUID binary encoding is 16 RFC-4122 network-order
bytes, never Windows GUID memory order. Times are integer Unix milliseconds
in `0...2^53-1`; operational deadlines use monotonic time. Hashes are 64
lower-case hex characters. Base64url is canonical, unpadded and decoded-size
checked. Unknown object fields are ignored, including a known field name in a
message where that field has no defined meaning.

Every JSON message has `v:3`, an exact defined upper-case `type`, and a random
UUIDv4 `message_id`. Process control messages in wire order on a serialized
state executor. Retain up to 2,048 message IDs for ten minutes per connection;
an entry evicted due to capacity is outside that bounded replay window.
Unknown types receive ERROR/unknown_message_type and close; wrong versions
receive ERROR/incompatible_version and close. Structural validation errors
receive ERROR/invalid_frame, invalid_json or invalid_field and close. ERROR
`code` matches `[a-z0-9_]{1,48}`; `detail` is 0 through 128 UTF-8 bytes, MUST NOT
contain payloads/secrets, and MAY be empty. Optional `reply_to` is a message ID.
Schema validation is supplemented by byte-count, canonical encoding, sorted
list, hash, framing and state checks; schemas alone are not a decoder.

HELLO fields are `device_id`, `device_name` (1 through 64 UTF-8 bytes),
`platform`, `capabilities`, `certificate_sha256`, and 32-byte `session_nonce`.
Both send HELLO first. Devices generate fresh random nonces per connection.
Bind ID, SAN, actual certificate and expected target before accepting traffic.
Define the following binary value once both HELLOs validate:

```text
control_binding_sha256 = SHA256(
  ASCII("FLOATCUT-CONTROL-V3\0")
  || TCP dialer UUID16 || dialer certificate SHA32 || dialer HELLO nonce32
  || TCP listener UUID16 || listener certificate SHA32 || listener HELLO nonce32)
```

Roles are TCP roles, independent of file-sender or pairing roles. Compare the
32 decoded hash bytes. A replacement control connection has a new binding.
An old file acceptance token never authorizes a replacement connection.

## 5. V3 pairing, resume and revocation invariants

V3 replaces v2's nonce-first pairing with commit/reveal. Generate each 32-byte
nonce using a CSPRNG before sending its commitment. Freeze role, request ID,
both device IDs/pins and the original control binding before either reveal:

```text
commitment(role, own_nonce) = SHA256(
  ASCII("FLOATCUT-PAIR-COMMIT-V3\0") || role_byte
  || request UUID16 || original control binding32
  || initiator UUID16 || initiator certificate SHA32
  || acceptor UUID16 || acceptor certificate SHA32 || own_nonce32)
role_byte = 00 for initiator, 01 for acceptor
```

The 201-byte commitment input and ordering are normative:

1. Initiator sends PAIR_REQUEST with `request_id`, `initiator_commitment_sha256`.
2. Acceptor requires explicit local acceptance, then sends PAIR_CHALLENGE with
   `request_id`, `acceptor_commitment_sha256`.
3. Initiator sends PAIR_REVEAL with `request_id`, `role:initiator`, `nonce`.
4. Acceptor verifies that reveal against the stored commitment before sending
   its PAIR_REVEAL with `role:acceptor`. Initiator verifies it likewise.
5. Both derive the same transcript and show a comparison code. No code is
   presented, and no CONFIRM is legal, before both commitments/reveals validate.

Each commitment/reveal occurs once per request. A duplicate with a fresh message
ID is invalid_state. A mismatch causes PAIR_REJECT/commitment_mismatch, persistent
request invalidation and close. A reveal before the required phase is rejected.

```text
transcript = ASCII("FLOATCUT-PAIR-V3\0") || request UUID16
  || original control binding32
  || initiator UUID16 || initiator certificate SHA32 || initiator nonce32
  || acceptor UUID16 || acceptor certificate SHA32 || acceptor nonce32
  || initiator commitment32 || acceptor commitment32
```

Hash this 289-byte transcript with SHA-256. The comparison code is the first
four hash bytes as unsigned big-endian integer modulo 1,000,000, padded to six
digits. This construction is specified here for independent review; the
[commitment rationale in RFC 6189](https://www.rfc-editor.org/rfc/rfc6189.html#section-4.4.1.1)
does not constitute a review or endorsement of Floatcut's construction.
The shared pairing vector has transcript hash
`45eb4cba98ec26a1610a3d399dea46194824411e3aed0fa6d27f374eb6454caf`
and comparison code `048506`. Its control binding input is 180 bytes and hash
`bd1de67d2f5d22197092183081ed052262f959748c2332e5385582280d474beb`.

PAIR_CONFIRM and PAIR_COMPLETE contain `request_id`, `transcript_sha256`.
Trust requires this user's explicit code confirmation and a matching remote
PAIR_CONFIRM or truthful PAIR_STATUS/confirmed or PAIR_STATUS/complete. These
statuses set only the remote confirmation flag. PAIR_COMPLETE alone MUST NOT
manufacture a missing confirmation. Matching COMPLETE is idempotent once both
confirmations exist; it does not renew any expiry or paired timestamp.

After both reveals, persist request, original binding/context, peer pin, role,
transcript and each confirmation flag. The initiator's 120-second deadline starts
when it queues PAIR_REQUEST; the acceptor's starts when it receives that valid
request. No retry extends either deadline. Persist the fixed boot-scoped elapsed
deadline and local boot generation, using the native mappings in
V3_IMPLEMENTATION. A same-boot process restart resumes only while that original
deadline is still valid. Reboot, missing/changed boot marker or backward elapsed
time invalidates an uncompleted record; never reconstruct `now + 120 seconds`
or use a wall-clock jump to renew it. Do not resume
a disconnected exchange before both reveals: invalidate it and require a new
user action. Keep a completed record for exactly ten minutes from its first
completion, with no early compaction or renewal. Its fixed elapsed deadline and
boot generation are persisted too; changed boot generation retires that recovery
record but never deletes an already established peer pin. Nonces may be erased once the
verified transcript is persisted; the code can be derived from that hash.

PAIR_STATUS contains request/hash and `state`:
`awaiting_confirmation` means this user has not confirmed; `confirmed` means
this user has confirmed; `complete` means this side persisted both confirmations
and its peer record. Receiving a remote state never changes the local user flag.
The original pairing initiator dials a resume even if larger or `pair=0`.
The new connection authenticates the same pin, but resumes the stored original
transcript rather than rehashing it with new HELLO nonces. A pinned mismatch
fails without deleting the legitimate pending record. Missing/expired/mismatched
records receive invalid_state. Rejection/cancellation invalidates pending state.
An unconfirmed resumed user can confirm the original code before fixed expiry.

PAIR_REJECT reasons are v2's reasons plus `commitment_mismatch` and `pairing_busy`. At capacity,
new requests receive peer_limit; when new pairing is disabled, pairing_disabled;
a currently paired peer's new request receives already_paired. Initial request
admission precedence is invalid_request, already_paired, pairing_disabled,
peer_limit, pairing_busy. At most three uncompleted pairing requests are active
per engine, with at most one per peer. A second otherwise valid request for that
peer or a fourth concurrent request receives pairing_busy, not peer_limit.

A local trust generation is persistent and changes on unpair and fresh pairing.
Revocation has precedence over resume and trusted traffic. Persist the tombstone
before removing the active peer; invalidate all older pending records,
reservations, callbacks and file tokens/channels immediately. Only fresh
commit/reveal plus explicit confirmations can replace that tombstone.
UNPAIR/UNPAIR_ACK use v2 fields. A historic pin on an incoming control connection
may authorize only idempotent UNPAIR acknowledgement, never normal Trust. ACK
loss is retried with the same revocation ID. A matching ACK is persisted and the
revocation-only connection closes. A changed certificate gets no exception.

Control PING/PONG, text and image shapes are v2's with `v:3`. Text and image
size/hash/source checks, private staging and no forwarding still apply. Image
ACK terminal statuses must work both at offer and commit. DATA beyond the
declared image chunk count/size is invalid and removes partial data. A control
keepalive is sent after 30 seconds idle; 90 seconds without authenticated
received control messages ends the control connection. File traffic does not
reset this timer. Reconnect uses 1, 2, 4, 8, 16, then at most 30 seconds with
jitter while the peer remains discovered and eligible.

## 6. File offer and acceptance on control

Only an enabled, pinned Trusted control connection permits file control.
A compliant sender initiates FILE_OFFER only with mutual `file.transfer.v1`;
a well-formed offer on Trusted without that intersection receives
REJECT/unsupported. Other unsolicited file control receives invalid_state.
The user chooses one target device ID;
the sender MUST NOT expand that choice into broadcast/fan-out. Reserve the
outgoing slot before source preparation. The sender freezes
the exact bytes in a private snapshot before offering, computes size and hash
over that snapshot, and streams that same snapshot. Failure to prepare it is a
local failure; no offer is sent. No source path is transmitted.
Before queuing OFFER, persist private outbound status metadata: selected peer
ID/pin/trust generation, transfer ID, original offer digest, size/hash and display
name. This permits read-only status recovery after a sender process restart;
it is not an offline sending queue. Restart removes any snapshot and never
automatically resends bytes or offers. After ACCEPT the receiver alone remains
authoritative about the eventual saved outcome.

FILE_OFFER fields:

| Field | Exact constraint |
| --- | --- |
| `transfer_id` | Random canonical UUIDv4, never reused by the sender |
| `target_device_id` | Exactly the authenticated receiving device ID |
| `file_name` | Portable suggested basename defined below |
| `byte_size` | Integer 0 through 8,589,934,592 |
| `content_sha256` | Hash over all raw file bytes, including the empty stream |
| `offer_sha256` | Binary offer digest below |

`file_name` is NFC Unicode, 1 through 180 UTF-8 bytes, contains no U+0000–001F,
U+007F or any of `/`, `\`, `:`, `<`, `>`, `"`, `|`, `?`, `*`, is not `.` or `..`,
and has no trailing U+0020 or dot. To produce a portable suggestion, normalize
the local basename to NFC, replace each forbidden scalar with `_`, remove
trailing spaces/dots, truncate at a Unicode scalar boundary to 180 bytes, remove
trailing spaces/dots again, and use `file` if empty. The receiver validates
instead of silently repairing a wire name. Case is preserved; truncation has
no extension-specific handling and may shorten an extension.
The receiver's chosen directory/path is local policy and never sent to the peer.

```text
offer_sha256 = SHA256(
  ASCII("FLOATCUT-FILE-OFFER-V1\0") || transfer UUID16
  || original control binding32 || sender UUID16 || receiver UUID16
  || byte_size U64BE || content SHA32
  || file_name UTF8 byte length U16BE || file_name UTF8 bytes)
```

Use the offer's original connection binding and IDs, not UUID sorting. JSON
order and unknown fields do not affect this digest. The `report.txt` / `abc`
fixture has a 155-byte manifest input and digest
`00391de54fc3779c06894d716dd409d0dfaec13be6e7d38f4360f8dc734507d8`.
The receiver validates
target, capability, manifest, quotas and filename before displaying the offer.
It reserves the incoming transfer slot atomically upon admitting a valid offer,
before showing a decision window. It MUST obtain an explicit receiving decision and local destination before
acceptance; pairing alone never authorizes saving arbitrary files. No automatic
accept rule is part of file profile 1. It MAY reject without a prompt according
to receiving preference, quota, destination support or disk capacity.

FILE_REJECT contains `transfer_id`, `reason`, one of `user_rejected`, `disabled`,
`busy`, `too_large`, `no_space`, `invalid_offer`, `duplicate_transfer`, `timeout`,
`unsupported`, `unsupported_destination`, `destination_exists`. It is terminal before acceptance.
The sender sends no data after rejection. Transfer IDs are unique across the
receiver engine, not merely within one peer. Duplicate IDs known from a live
transfer, recent offer or retained receipt receive duplicate_transfer, even if
metadata matches. The recent never-accepted offer cache is bounded to 1,024 IDs
and ten minutes; when full, reject new offers with busy until space expires.

FILE_ACCEPT contains `transfer_id`, `offer_sha256`, 32 CSPRNG bytes as
`accept_token`, and `expires_in_ms:15000`. Before sending it, verify continued
ownership of the reserved transfer slot, atomically reserve a durable receipt
slot and a local destination, and flush a private accepted journal record.
That record contains the offer and recovery metadata but no token. The token
maps to the exact manifest, both current pins, local trust generation, control
connection/epoch/binding and transfer ID. Never log/persist its secret value.
The receiver's monotonic 15-second deadline starts when ACCEPT is queued for
transport. A valid OPEN must claim it before that deadline. Clock fields on the
wire do not override that deadline.

## 7. File data connection and binary framing

After ACCEPT, the sender creates one extra TLS connection to the receiver's same
listener, offering only `floatcut-file/1`. The receiver verifies current pin,
trust generation and live origin control, then receives FILE_OPEN:
`transfer_id`, `offer_sha256`, `control_binding_sha256`, `accept_token`.
No file bytes are legal yet. Validate all bindings, expiry and unused-token
state before atomically claiming the token. An invalid candidate closes without
consuming an otherwise valid token. A successfully claimed token is single-use;
concurrent duplicate OPEN cannot claim it. There is no retry with a consumed
token. A failed transfer requires a fresh user action and transfer ID.

Create a private temporary file in the destination filesystem only after the
claim succeeds. Receiver sends FILE_READY with `transfer_id`, `offer_sha256`,
`chunk_size:262144`. The sender validates it before sending bytes. OPEN/READY
are the only normal JSON preludes on this connection; ERROR is allowed before
READY. After READY there are no JSON messages, clipboard traffic, pairing,
heartbeat, token refresh or file control on the data stream.

Binary records have exactly `opcode U8 || payload_length U32BE || payload`:

| Opcode | Payload | Payload length |
| --- | --- | --- |
| `01` DATA | `offset U64BE || raw bytes` | 9 through 262,152 |
| `02` END | `byte_size U64BE || complete SHA256 raw32` | Exactly 40 |

Offsets start at zero and equal the receiver's previously validated byte count.
Every DATA contains exactly `min(262144, byte_size-offset)` bytes; DATA is illegal
when remaining bytes are zero. Validate opcode/length/offset/remaining budget
before writing. An empty file sends END and no DATA. Unknown opcodes, partial
headers, wrong lengths, early END, out-of-order offsets and overflow fail the
transfer. TCP reads/writes and TLS records are not application record boundaries.
Parsers handle every fragmentation/coalescing; unsigned integers use network
order on all platforms. No compression or base64 is used for file bytes.

The receiver incrementally hashes validated bytes. END's size and hash must
equal both the offer and the received bytes/hash. The first valid END ends the
data phase; close the data connection and proceed to publication without waiting
for platform-dependent half-close/EOF. Sender MUST NOT send anything after END;
receiver does not process later data. EOF before valid END fails. Data errors
are reported via the control FILE_RESULT and delete unpublished staging.

Applications MUST stream with bounded buffers and transport backpressure, never
load the whole file into RAM. Each transfer may retain at most one DATA record
(262,152 payload bytes) in its application receive buffer and one in its send
buffer, plus one JSON prelude. TLS/socket-library buffers are separate bounded
transport resources. Data workers cannot block the control executor/UI thread.
Control heartbeats, clipboard and UNPAIR keep their normal deadlines during
large file transfers.

## 8. Results, cancellation and exact deadlines

FILE_RESULT is authored by the file receiver. It contains `transfer_id`,
`offer_sha256`, `status`, with these status-dependent fields:

| Status | Additional fields / meaning |
| --- | --- |
| `saved` | `byte_size`, `content_sha256`, exactly matching the accepted offer; durable publication and receipt completed |
| `pending` | `phase`: `offered`, `accepted`, `receiving` or `committing`; response to a status query or late CANCEL after irrevocable publication authority was granted |
| `unknown` | `reason:receipt_missing`; only a response to a status query |
| `cancelled` | `reason`: `user_cancelled`, `peer_cancelled` or `revoked` |
| `failed` | `reason`: `data_timeout`, `channel_timeout`, `control_lost`, `io_error`, `size_mismatch`, `hash_mismatch`, `invalid_data`, `no_space`, `destination_exists` or `invalid_state` |

### 8.1. Authoritative progress for both status windows

FILE_PROGRESS contains `transfer_id`, `offer_sha256`, `received_bytes` and
`phase` (`receiving` or `committing`). Only the file receiver authors it.
`received_bytes` is an integer from zero through the offered size, counting
complete validated DATA records successfully written to private staging.
Queued sender bytes, socket write completion and partial records never count.
The receiver queues initial `receiving/0` on control before queuing FILE_READY
on data. Consequently the sender may receive that progress before READY.

While the counter advances, emit one update every 1,000 ms, with at most one
intermediate update per 1,000 ms. No periodic update is needed without new
written bytes. The initial update and the immediate `committing/byte_size`
update after valid END are phase events exempt from that rate limit. Emit
committing only once the full size/hash verifies. Progress cannot reset a
deadline. Receiver and sender UIs use the same authoritative local/received
counter, with normal control-transport delay between displays.

For nonempty files, percentage is integer `floor(100 * received_bytes / byte_size)`
using arithmetic that cannot overflow at 8 GiB. Empty files display zero before
valid END and 100 only in committing/saved. A receiving count must be a multiple
of 262,144 or exactly the offered size. Counters never decrease; phase can move
only receiving to committing, and committing requires the complete size. A
wrong author, offer hash, counter/phase regression or excess count is
ERROR/invalid_state. Identical repeated progress is harmless and never renews
deadlines. Progress after terminal RESULT is ignored for the known transfer;
it cannot replace the terminal outcome. Unknown-transfer progress is invalid_state.

On both native clients the same transfer-status component and state model are
used. The sending window opens at the explicit Send action; the receiving
window opens on a valid admitted OFFER, before acceptance. Sender state shows
preparation and then waiting for approval; receiver shows approval required
with Accept/Reject. Both expose explicit Cancel before committing; during
committing the button is disabled because publication may already be irrevocable.
After acceptance show connecting, then transmitting/receiving with the common
percentage. Committing shows saving/verifying, even at 100%; only saved RESULT
shows success. Rejected, cancelled, failed and unconfirmed have distinct states.
Window close hides the presentation only; it neither accepts nor cancels.
An explicit Reject/Cancel action performs that protocol transition. A hidden
window remains reopenable by transfer ID and does not alter its deadline.

### 8.2. Terminal success and cancellation

The sender reports success only on matching saved size/hash. END, socket close
and UI progress of 100% do not mean saved. After END or possible publication,
loss of RESULT is `unconfirmed` locally, not a claim that the file was not saved.
On unconfirmed the sender retires its data work, removes the snapshot and
releases its outgoing transfer slot, retaining only status-recovery metadata.
Read-only recovery may update that displayed outcome without allocating another
transfer slot. The receiver's outstanding committing work retains its own slot
until its actual terminal result resolves.
Receiver result author/offer identity mismatches are control invalid_state.

Either side may send FILE_CANCEL with `transfer_id`, `reason` equal to
`user_cancelled`, `timeout`, `io_error`, `revoked`, `control_lost` or `data_error`.
Before the irrevocable publication grant it invalidates work and closes the
data connection. The receiver
authors RESULT even when it sends CANCEL itself; the sender never authors RESULT.
For a live transfer without a publication grant, map CANCEL to RESULT exactly as follows:

| CANCEL reason and author | Receiver RESULT |
| --- | --- |
| `user_cancelled` from sender | cancelled/peer_cancelled |
| `user_cancelled` from receiver | cancelled/user_cancelled |
| `revoked` from either side | cancelled/revoked |
| `io_error` from either side | failed/io_error |
| `data_error` from either side | failed/invalid_data |
| `control_lost` | failed/control_lost, persisted locally if control is already gone |
| `timeout` while offered/accepted | failed/channel_timeout |
| `timeout` while receiving | failed/data_timeout |
| `timeout` while committing | failed/io_error |

Cancellation after an earlier REJECT returns that original REJECT if retained;
it cannot change the outcome. Receiver-origin CANCEL is followed by its RESULT
in control wire order when the control still permits traffic.
Before acceptance, cancellation also invalidates
the offer UI; a delayed local accept cannot revive it. CANCEL after publication
authority is granted returns pending/committing while the operation is unresolved,
or its existing terminal result once known, if the control still permits traffic. It MUST
NOT remove a published file or report cancelled for it. Late terminal messages
for the same transfer are idempotent only if consistent with the stored outcome.

| Deadline | Start and required outcome |
| --- | --- |
| Control/TLS/HELLO establishment | 15 s from attempt/candidate start |
| Receiver user decision | 60 s from a valid OFFER; then REJECT/timeout |
| Sender waiting for ACCEPT/REJECT | 90 s from sending OFFER; cancel on expiry |
| ACCEPT token/OPEN | 15 s from receiver queuing ACCEPT; then failed/channel_timeout |
| Sender waiting for READY | 5 s from sending OPEN; close and cancel on expiry |
| Data idle/incomplete record | 30 s since READY or last complete validated DATA; raw TCP bytes do not renew it |
| Entire accepted transfer | 7,200 s from ACCEPT; work without a publication grant is cancelled on expiry |
| Commit/publication preparation | 30 s from valid END through publication grant; without a grant, expiry fails/io_error |
| Sender waiting for terminal RESULT | 45 s from sending END; then local unconfirmed and status recovery |

At `elapsed_now >= deadline` the deadline has expired; eligibility checks must
reject a token/decision/worker result at equality, even if the timer callback
has not run. OPEN is timely only when its validated atomic claim completes
strictly before the receiver's deadline. Runnable engines process expiry within
one second; after suspend they reconcile expired work before UI or publication.
Deadlines do not renew due to progress, retransmission, queries, callback
duplication or wall-clock changes. A complete DATA renews only the data-idle
deadline. Cancel/revoke/timeouts and publication authorization are serialized.
After file flush and prepared-journal persistence, the executor rechecks
ownership, epoch, generation and deadlines, then grants exactly one irrevocable
publication operation to a worker. This grant is the cancellation linearization
point: before it, cancellation forbids publish; after it, a kernel rename already
authorized cannot be reliably cancelled. The operation still must succeed and
persist its saved receipt before success is reported. A collision/I/O failure
still returns the actual failure. No timeout may falsely declare an already
granted operation failed; unresolved work remains committing/unconfirmed.
Native rename/flush work MUST NOT block the control executor. While a worker is
unresolved, clipboard, heartbeat and status query remain responsive.

Control disconnect, engine shutdown, peer disable or unpair invalidates all
transfers/tokens without a publication grant immediately. An already granted
operation resolves to its actual outcome; it creates no new trust or transfer
permission. Data traffic never keeps a lost
control connection alive. There is no byte resume, automatic resend, retry
queue, forwarding or history backfill. After rejection/failure, retry requires
another explicit user action, a new ID and a new receiving decision.

## 9. Filesystem publication, receipts and restart recovery

Use a private temporary file on the same filesystem as the chosen destination:
owner-only permissions/DACL, exclusive creation, no-follow directory resolution
and retained directory/file handles. Wire names cannot select directories or
traverse symlinks/reparse points. Default final basename is
`<transfer_id>-<file_name>` (at most 217 UTF-8 bytes). A receiver may instead
choose its own local basename/path before ACCEPT. In every case publication
is atomic and MUST NOT replace an existing file, including a race-created file.
Do not implement this as an existence check followed by overwrite-capable rename.
Unsupported destinations are rejected before ACCEPT with unsupported_destination.

After valid END, flush all file bytes using the native durable-storage API.
Persist a private `prepared` journal record with transfer/offer IDs, peer ID,
pin, local trust generation, size/hash and local staging/final names. Flush the
journal before atomic exclusive publication. Include the staging file's stable
filesystem identity (POSIX device/inode; Windows volume and file ID), not merely
a pathname. After the serialized publication grant, publish on a worker and perform the destination's
native durability operations, then persist/flush the terminal saved receipt.
Only then send FILE_RESULT/saved. POSIX directory fsync is not assumed to be
available on Windows; implementations must use the platform operations and
restart recovery documented in [V3_IMPLEMENTATION.md](V3_IMPLEMENTATION.md).
Conformance covers process crashes/restarts, not a guarantee against every
hardware/filesystem power-loss behavior.

Startup reconciliation completes before accepting file offers or status
queries. For each prepared journal: an existing regular final file with the
same recorded filesystem identity AND exactly matching size/hash resolves to
saved and repairs the receipt; no final file resolves to
failed/control_lost and deletes staging. A conflicting final file, even one with
identical bytes but a different identity, is neither
overwritten nor deleted; report failed/io_error and retain private diagnostics.
Failure after publication MUST NOT report failed/cancelled merely because
receipt writing failed: retain prepared evidence and recover, or leave the
sender unconfirmed until recovery. Once a saved receipt exists it records the
historical completion; a user's later move/delete does not change it to failed.

Persist accepted terminal receipts for 24 hours; expiry is an epoch timestamp
for retention only, not an operational deadline. Reserve a receipt place before
ACCEPT; if none is available without evicting an unexpired receipt, REJECT/busy.
Journal and receipts are versioned private metadata, not file-byte history or
trust-store payloads. Tokens are never persisted. On startup, accepted transfers
that were not prepared are failed/control_lost and their partial data is removed.
Never automatically reopen a data channel after restart.

FILE_STATUS_REQUEST contains `transfer_id`, `offer_sha256`. It is permitted on
a new Trusted control connection authenticated as the same peer ID/pin and
local trust generation as the receipt. It returns FILE_RESULT with the original
offer hash; the old control binding is NOT required for this query. It never
issues a token or resumes bytes. Live transfers return pending; receipts return
their terminal outcome; missing/expired/unaccepted transfers return unknown.
Rejections and cancellations before ACCEPT need not have a durable receipt;
unknown must never cause automatic reoffering or a false success claim.

## 10. Privacy, errors and implementation gates

Diagnostic logs contain event, short transfer/peer IDs, phase, byte counts and
stable reason codes. They MUST NOT contain file bytes, filenames, local paths,
tokens, pairing nonces/codes, full transcript/binding hashes or raw messages.
The explicit local transfer UI may show filename/destination. Control data and
file bytes are never copied into generic clipboard logs or peer/pairing stores.

Framing/lexical errors follow ERROR then connection close. FILE_OFFER admission
uses this exact precedence after framing and before full profile-schema validity:

1. Require Trusted and a current peer pin. Otherwise ERROR/not_paired and close.
2. Validate envelope, transfer UUID, every required field's JSON type, canonical
   target UUID and hash encodings. Require byte_size in `0...2^53-1`. Missing,
   wrong-type or noncanonical fields cause ERROR/invalid_field and close.
3. Without the mutual file capability, REJECT/unsupported.
4. byte_size above 8 GiB receives REJECT/too_large.
5. Invalid portable/NFC/name-byte rules, wrong target or wrong offer digest
   receive REJECT/invalid_offer. Validity schemas intentionally reject these
   values; that does not override this semantic response classification.
6. Duplicate ID receives duplicate_transfer; disabled receiving receives
   disabled; exhausted transfer/cache quota receives busy, in that order.
7. Admit and reserve the offer slot. At local acceptance, an existing selected
   destination receives destination_exists, an unsupported destination receives
   unsupported_destination, insufficient space receives no_space, and exhausted
   receipt quota receives busy. None may send ACCEPT or allocate a payload file.

A malformed file
prelude closes that data candidate; a failure after a valid token claim also
fails the accepted transfer. A well-formed offer with wrong target/digest/name
receives REJECT/invalid_offer; size above the file-profile limit receives
REJECT/too_large without staging allocation. Valid but unsupported capability
receives REJECT/unsupported. An unknown transfer/control state receives
ERROR/invalid_state without creating transfer state. Valid runtime/disk/user
failures use the defined REJECT/RESULT/CANCEL reasons, not free-form wire detail.

Independent implementation gates are: strict wire/schema fixtures, complete
pairing commitment/transcript vectors and independent cryptographic review,
fragmented binary parsing and size boundaries, true mTLS+ALPN, platform atomic
no-overwrite publication, crash journal reconciliation, crossed sender/TLS/UUID
roles, cancellation/revocation races and lost-result recovery. Shared fixtures
are under `fixtures/v3/`, schemas under `schemas/v3/`. Passing them validates
contract artifacts; working macOS↔Windows↔Python interoperability is a separate
mandatory gate.
