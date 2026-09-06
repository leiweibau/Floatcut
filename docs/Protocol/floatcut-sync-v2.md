# Floatcut Sync Protocol v2 (normative)

This document is the platform-neutral wire contract. RFC 2119 terminology is
normative. Version 2 is based on v1 and adds bounded, chunked PNG/JPEG clipboard
image transfer. A v1 implementation is not wire-compatible with v2.

## Discovery and version selection

- DNS-SD type: `_floatcutsync._tcp`.
- TXT keys: `id` (lower-case UUIDv4), `pv=2`, `platform`,
  `caps=clip.image.jpeg,clip.image.png,clip.text.utf8`, and `pair=0|1`.
- Capability names are lower-case ASCII, comma-separated, unique, and sorted
  bytewise. The three capabilities above are mandatory in v2. An implementation
  MUST NOT connect when `pv` is not exactly `2` or a mandatory capability is
  absent.
- DNS and DNS-SD names MUST be compared using ASCII case-insensitive DNS
  semantics. A trailing root dot is optional for comparison. Implementations
  SHOULD retain the originally received spelling for presentation and use the
  normalized form only for lookup, expiry, removal, and deduplication.
- Publishers MUST emit the defined TXT keys `id`, `pv`, `platform`, `caps`, and
  `pair` in lower case. Receivers MUST match TXT keys ASCII-case-insensitively.
  TXT values remain case-sensitive and MUST satisfy their exact field rules.
  Duplicate keys that differ only in ASCII case, such as `id` and `ID`, make the
  complete advertisement invalid.
- `pair=1` means that the device accepts new incoming `PAIR_REQUEST` messages.
  `pair=0` suppresses only new pairings; trusted peers and resumable pending
  handshakes remain functional. A new request is answered with
  `PAIR_REJECT/pairing_disabled`.
- The SRV record is the only source of the TCP port. Instance names and TXT data
  are untrusted and MUST NOT contain clipboard content, keys, certificates,
  nonces, or comparison codes.

## TLS identity

TCP is protected by mutual TLS 1.3. The certificate profile, structural checks,
SAN-to-device-ID binding and full-certificate pinning rules are unchanged from
v1: persistent self-signed ECDSA P-256/SHA-256, ten-year validity, `CA=false`,
`digitalSignature`, EKUs `serverAuth` and `clientAuth`, and SAN URI
`urn:floatcut:device:<device-id>`. An unpaired certificate is accepted only on a
pairing channel after structural and self-signature validation. A paired
connection MUST match its stored full-DER SHA-256 pin.

Trust records created by v1 MUST NOT automatically authorize v2. They may be
migrated only after an implementation-specific, explicit local decision or a
new v2 comparison-code pairing.

## Framing and common representation

Every message is a four-byte unsigned big-endian JSON byte length followed by
exactly that many strict UTF-8 bytes. Length zero and lengths above 1,048,576
are invalid. JSON nesting is limited to eight. Duplicate keys, floats,
exponents, `NaN`, and infinities are invalid. There is no compression and no
line delimiter.

Every object contains `v: 2`, an upper-case `type`, and a random canonical
lower-case UUIDv4 `message_id`. Times are Unix epoch milliseconds encoded as
integers in `0...2^53-1`. Hashes are SHA-256 encoded as 64 lower-case hex
characters. Nonces and image chunks use canonical unpadded base64url. Unknown
fields are ignored. An unknown `type` produces `ERROR/unknown_message_type`;
any `v` other than `2` produces `ERROR/incompatible_version` and closes the
connection.

Messages on one connection are processed in wire order. A `message_id` may
occur only once in the ten-minute, 2,048-entry replay window.

## HELLO, pairing, and control messages

`HELLO` remains the first application message in each direction and contains
`device_id`, `device_name` (at most 64 UTF-8 bytes), `platform`,
`capabilities`, `certificate_sha256`, and a 32-byte `session_nonce` encoded as
unpadded base64url. `capabilities` is the bytewise-sorted JSON array
`["clip.image.jpeg","clip.image.png","clip.text.utf8"]`. It MUST agree with
the DNS-SD `caps` value. Device ID, certificate SAN, and actual certificate hash
MUST agree.

Pairing messages and required fields are:

- `PAIR_REQUEST`: `request_id`, `initiator_nonce`;
- `PAIR_CHALLENGE`: `request_id`, `acceptor_nonce`;
- `PAIR_CONFIRM`: `request_id`, `transcript_sha256`;
- `PAIR_STATUS`: `request_id`, `transcript_sha256`, `state` (`confirmed` or
  `complete`);
- `PAIR_COMPLETE`: `request_id`, `transcript_sha256`;
- `PAIR_REJECT`: `request_id`, `reason` (`user_rejected`, `timeout`,
  `peer_limit`, `pairing_disabled`, `already_paired`, or `invalid_request`).

Both users independently verify and confirm the same six-digit code. Trust is
created only after both valid `PAIR_CONFIRM` messages. Both sides may send
`PAIR_COMPLETE` concurrently. A matching completion is terminal and
idempotent, including after the connection entered `Trusted`; a mismatch is
`ERROR/invalid_state`.

Control messages and required fields are:

- `CLIPBOARD_ACK`: `clip_id`, `status` (`ready`, `applied`, `duplicate`,
  `skipped`, `unsupported`, or `invalid`);
- `PING`: `sent_at_ms`; `PONG`: `reply_to`, which is the PING `message_id`;
- `UNPAIR`: `revocation_id`, `revoked_at_ms`, and optional
  `reason=user_request`; `UNPAIR_ACK`: `revocation_id`;
- `ERROR`: `code`, `detail`, and optional `reply_to`.

The minimum error-code set is `invalid_frame`, `invalid_json`,
`incompatible_version`, `unknown_message_type`, `not_paired`,
`identity_mismatch`, `invalid_state`, `payload_too_large`, `hash_mismatch`, and
`rate_limited`. Error detail MUST NOT include clipboard content, certificate
material, nonces, transcript hashes, or comparison codes. See the v2 schemas
for machine-readable field constraints.

The pairing transcript differs from v1 only in its domain separator:

```text
ASCII("FLOATCUT-PAIR-V2\0")
|| initiator UUID as 16 RFC-4122 bytes
|| initiator certificate SHA-256 as 32 raw bytes
|| initiator nonce as 32 raw bytes
|| acceptor UUID as 16 RFC-4122 bytes
|| acceptor certificate SHA-256 as 32 raw bytes
|| acceptor nonce as 32 raw bytes
```

The input is 177 bytes. Hash it with SHA-256. Interpret bytes 0...3 as an
unsigned big-endian integer, reduce modulo 1,000,000, and format six decimal
digits. The v2 normative vector produces hash
`ab448a18d3e47f6fbcc7426d3dc1880a161be470d8b59c64f63f84fbc0da9ad5`
and comparison code `395736`.

## Text clipboard transfer

`CLIPBOARD_UPDATE` is unchanged in shape from v1 except for `v: 2`. It contains
`clip_id`, `source_device_id`, `created_at_ms`, `content_type` (exactly
`text/plain;charset=utf-8`), `utf8_size`, `content_sha256`, `hop_count`
(exactly `0`), and `content`. Content is 1 through 524,288 UTF-8 bytes, is not
normalized or trimmed, and preserves line endings.

The receiver answers with `CLIPBOARD_ACK`, containing `clip_id` and a terminal
status: `applied`, `duplicate`, `skipped`, `unsupported`, or `invalid`.

## Image clipboard transfer

Only PNG (`image/png`) and JPEG (`image/jpeg`) byte streams are legal. The
sender chooses the representation; PNG is the lossless clipboard interchange
format. Animated content, metadata, color profiles, and alpha are carried only
when the selected format supports them. Receivers MUST treat bytes as untrusted
and apply decoder-specific pixel, memory, and metadata limits when importing
them into a native clipboard.

An image is at most 16,777,216 bytes. PNG is at least 8 bytes and JPEG is at
least 3 bytes, matching their required signatures. It is transferred by this
exchange:

```text
Sender                                      Receiver
  CLIPBOARD_IMAGE_BEGIN  ------------------>
                         <------------------  CLIPBOARD_ACK/ready
  CLIPBOARD_IMAGE_CHUNK index=0  ---------->
  ... strictly increasing indexes ...
  CLIPBOARD_IMAGE_CHUNK index=n-1  -------->
  CLIPBOARD_IMAGE_COMMIT  ----------------->
                         <------------------  CLIPBOARD_ACK/terminal
```

`CLIPBOARD_IMAGE_BEGIN` contains:

- `clip_id`: transfer identity, canonical lower-case UUIDv4;
- `source_device_id`: the authenticated direct sender;
- `created_at_ms`: creation time;
- `content_type`: exactly `image/png` or `image/jpeg`;
- `byte_size`: complete decoded image byte count, 8...16,777,216 for PNG or
  3...16,777,216 for JPEG;
- `content_sha256`: SHA-256 over the complete image bytes;
- `chunk_size`: exactly 49,152;
- `chunk_count`: exactly `ceil(byte_size / 49,152)`, 1...342;
- `hop_count`: exactly `0`.

The receiver MUST validate the begin message before allocating a temporary
file. It then returns `CLIPBOARD_ACK` for the same `clip_id`: `ready` authorizes
chunks; `duplicate`, `skipped`, `unsupported`, or `invalid` is terminal and the
sender MUST send no chunks. The sender MUST wait for this acknowledgement.

Each `CLIPBOARD_IMAGE_CHUNK` contains `clip_id`, zero-based `chunk_index`,
`data_size`, `data_sha256`, and `data`. `data` is unpadded base64url. Decoded
chunks are exactly 49,152 bytes except the last, which is exactly the remaining
1...49,152 bytes. `data_size` and `data_sha256` cover decoded bytes, not the JSON
text. Indexes start at zero and increase by one. Only one incoming and one
outgoing image transfer may be active per connection; image chunks from two
clips MUST NOT interleave.

After every declared chunk, the sender emits `CLIPBOARD_IMAGE_COMMIT` with the
same `clip_id`. Before making the image visible, the receiver MUST verify the
chunk count, total byte count, complete SHA-256, and the media signature (the
eight-byte PNG signature or JPEG `ff d8 ff`). It MUST first write to a private
temporary file and atomically publish only a valid completed image. It then
returns terminal `CLIPBOARD_ACK/applied`. A semantic commit failure returns
`CLIPBOARD_ACK/invalid` and deletes all partial data. A malformed frame or
message follows the common `ERROR`/connection-close rules and also deletes all
partial data.

The sender may cancel with `CLIPBOARD_IMAGE_ABORT`, containing `clip_id` and an
optional reason `sender_cancelled`, `timeout`, or `io_error`. The receiver
deletes partial data and sends no acknowledgement. Closing the connection also
deletes partial data. There is no resume across connections and no offline
queue or history backfill.

## Trust, topology, and resource rules

Clipboard messages are legal only in `Trusted`, never on a revocation-only
connection. `source_device_id` MUST equal the authenticated direct peer. A
remote text or image clip MUST NEVER be forwarded.

Connection states are `AwaitingHello -> Pairing|Trusted -> Closing`. Messages
are processed serially. The smaller device UUID dials established connections;
the larger listens. The user initiator may dial during initial pairing. A
keepalive is sent after 30 seconds idle, the connection is lost after 90
seconds without received data, and reconnect delays are approximately 1, 2, 4,
8, 16, and at most 30 seconds with jitter. Reconnect stops when discovery is
lost.

Replay memory contains at most 2,048 message/clip IDs and expires entries after
ten minutes. Paired peers are limited to ten. Revocation tombstones are
persistent and can be replaced only by a new explicitly verified pairing.
Completed pending handshakes remain resumable for ten minutes; a pinned peer
that already compacted its local pending record still answers matching
`PAIR_STATUS/complete` idempotently. There is no clipboard offline queue,
history replay, or forwarding.

At most one incomplete received image (16 MiB decoded plus one JSON frame) is
retained per connection. Base64 is transport encoding only and does not change
`byte_size` or either hash. Implementations MUST delete incomplete image data on
any ordering, size, hash, signature, I/O, state, or connection error.
