# Floatcut Sync Protocol v1 (normative)

This document is the platform-neutral wire contract. RFC 2119 terminology is
normative. Implementations MUST NOT change values or encodings without a new
protocol major version.

## Discovery

- DNS-SD type: `_floatcutsync._tcp`
- TXT keys: `id` (lower-case UUIDv4), `pv=1`, `platform`,
  `caps=clip.text.utf8`, `pair=0|1`.
- `pair=1` means that the device currently accepts new incoming
  `PAIR_REQUEST` messages. `pair=0` suppresses only new pairings: established
  trusted peers and resumable existing pending handshakes remain functional.
  A new request received while `pair=0` is answered with
  `PAIR_REJECT/pairing_disabled`.
- The SRV record is the only source of the TCP port.
- Instance names and TXT data are untrusted and MUST NOT contain clipboard
  content, keys, certificates, nonces, or verification codes.

## TLS identity

TCP is protected by mutual TLS 1.3. Each installation has a persistent
self-signed ECDSA P-256 certificate using SHA-256, valid for ten years, with
`CA=false`, key usage `digitalSignature`, EKUs `serverAuth` and `clientAuth`, and
SAN URI `urn:floatcut:device:<device-id>`. An unpaired certificate is accepted
only on a pairing channel after structural and self-signature validation.
Paired connections MUST match the stored full-certificate SHA-256 pin.

## Framing and common representation

Each message is a four-byte unsigned big-endian JSON byte length followed by
exactly that many strict UTF-8 bytes. Length zero and lengths above 1,048,576
are invalid. JSON nesting is limited to eight. Duplicate keys are invalid.
There is no compression and no line delimiter.

All objects contain `v: 1`, an upper-case `type`, and a random lower-case
UUIDv4 `message_id`. IDs use canonical lower-case UUIDv4 text. Times are Unix
epoch milliseconds encoded as non-exponent JSON integers below 2^53. Hashes
are 64 lower-case hexadecimal characters. Nonces are exactly 32 bytes encoded
as unpadded base64url. Unknown fields are ignored. An unknown type produces
`ERROR/unknown_message_type`; an unsupported `v` produces
`ERROR/incompatible_version` and closes the connection.

## Messages

`HELLO` is the first application message in both directions and additionally
contains `device_id`, `device_name` (at most 64 UTF-8 bytes), `platform`,
`capabilities` (v1 contains `clip.text.utf8`), `certificate_sha256`, and
`session_nonce`. Device ID, certificate SAN, and actual TLS certificate hash
MUST agree.

Pairing messages and required fields:

- `PAIR_REQUEST`: `request_id`, `initiator_nonce`
- `PAIR_CHALLENGE`: `request_id`, `acceptor_nonce`
- `PAIR_CONFIRM`: `request_id`, `transcript_sha256`
- `PAIR_STATUS`: `request_id`, `transcript_sha256`, `state` (`confirmed` or
  `complete`)
- `PAIR_COMPLETE`: `request_id`, `transcript_sha256`
- `PAIR_REJECT`: `request_id`, `reason` (`user_rejected`, `timeout`,
  `peer_limit`, `pairing_disabled`, `already_paired`, or `invalid_request`)

Both sides can send `PAIR_COMPLETE` concurrently after their respective
`PAIR_CONFIRM` messages. A `PAIR_COMPLETE` with the active request ID and
transcript hash is therefore terminal and idempotent: a peer which already
entered `Trusted` MUST accept it as an acknowledgement without creating a
second peer record, sending `ERROR/invalid_state`, or closing the connection.
An otherwise mismatching `PAIR_COMPLETE` remains invalid state.

`CLIPBOARD_UPDATE` contains `clip_id`, `source_device_id`, `created_at_ms`,
`content_type` (exactly `text/plain;charset=utf-8`), `utf8_size`,
`content_sha256`, `hop_count` (exactly 0), and `content`. Content is 1 through
524,288 UTF-8 bytes, is not normalized or trimmed, and preserves line endings.
It is accepted only on a paired, pinned connection and only if source ID is the
authenticated direct peer. A remote clip MUST NEVER be forwarded.

`CLIPBOARD_ACK` contains `clip_id` and `status` (`applied`, `duplicate`,
`skipped`, `unsupported`, or `invalid`). It is diagnostic and never causes a
retry. `PING` contains `sent_at_ms`; `PONG` contains `reply_to`. `UNPAIR`
contains `revocation_id`, `revoked_at_ms`, and optional `reason=user_request`;
`UNPAIR_ACK` contains `revocation_id`. `ERROR` contains `code`, `detail`, and
optional `reply_to`.

## State and delivery

Connection states are `AwaitingHello -> Pairing|Trusted -> Closing`.
Clipboard data is legal only in `Trusted`. Messages are processed serially per
connection. The lexicographically smaller device UUID initiates established
paired connections; the larger listens. The user initiator may connect during
initial pairing. Keepalive is sent after 30 seconds idle and the connection is
lost after 90 seconds without received data. Reconnect delays are approximately
1, 2, 4, 8, 16, and at most 30 seconds with jitter and stop when discovery is
lost. There is no offline queue or history backfill.

Replay memory contains at most 2,048 message/clip IDs and expires entries after
ten minutes. Paired peers are limited to ten. Revocation tombstones are
persistent and are replaced only by a new explicitly verified pairing.

After a successful pairing, the complete pending handshake (request ID,
transcript hash, peer pin and both confirmation flags) MUST remain available
for ten minutes. On a reconnect with the same pinned identity, `PAIR_STATUS`
with `state: complete` resumes that terminal handshake. An implementation that
has already compacted this completed record MUST, when the peer is already
pinned and the channel is authenticated, respond idempotently with the matching
`PAIR_COMPLETE`; it MUST NOT close the connection solely because it has no
longer-lived pending record.

## Pairing transcript

Concatenate without lengths or JSON canonicalization:

```text
ASCII("FLOATCUT-PAIR-V1\0")
|| initiator UUID as 16 RFC-4122 bytes
|| initiator certificate SHA-256 as 32 raw bytes
|| initiator nonce as 32 raw bytes
|| acceptor UUID as 16 RFC-4122 bytes
|| acceptor certificate SHA-256 as 32 raw bytes
|| acceptor nonce as 32 raw bytes
```

Hash with SHA-256. Interpret hash bytes 0...3 as an unsigned big-endian
integer, reduce modulo 1,000,000, and format as six decimal digits. UUID bytes
MUST be RFC-4122 network order, never Windows GUID memory order.

The normative vector in `fixtures/pairing-vectors.json` has a 177-byte input,
hash `36794c2420c79ca869dd9655453b500589149947b0a22e36c2c365f4657755e1`,
and code `919012`.
