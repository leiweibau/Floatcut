# Floatcut Sync v2 – macOS conformance status

This status is intentionally separate from `CONFORMANCE.md`: the shared list
must not be signed off until an independent second implementation passes the
same fixtures and the bidirectional LAN matrix.

## Automated and passing

- Four-byte big-endian framing, fragmentation, coalesced maximum-size frames,
  and clean EOF handling.
- Zero/oversized/truncated lengths, invalid UTF-8, duplicate keys, depth 9,
  non-integer JSON numbers, incompatible versions, bad hashes, and the 512 KiB
  clipboard boundary.
- Pairing transcript length/hash and comparison code `395736` from the shared
  vector, including RFC-4122 network-order UUID bytes.
- Unicode and CR/LF round-trip without normalization.
- Persistent P-256 identity creation, separate-process reload, tagged recovery
  from a stale persistent reference, reset, missing-identity refusal,
  self-signed X.509 profile, full-certificate fingerprint, cryptographic
  key/certificate association, and usable `SecIdentity` association in the
  native login Keychain.
- Real loopback `NWListener`/`NWConnection` mutual TLS 1.3 with two independent
  identities, structural certificate validation, and SPKI association.
- Existing Floatcut engine regression suite, including search benchmark.
- Universal arm64/x86_64 Release app build, plist validation, and strict
  verification of the ad-hoc bundle signature.

Commands:

```sh
./Scripts/test-sync-protocol.sh
./Scripts/test-sync-identity.sh
./Scripts/test-sync-tls.sh
./Scripts/test-engine.sh
bash Scripts/package-app.sh
```

## Implemented and source-reviewed

- Exact `_floatcutsync._tcp` advertisement/TXT parsing and local-network plist
  declarations.
- Pin-before-trust, explicit two-sided pairing, timeout/resume, UUID connection
  direction, keepalive/backoff, replay/rate/peer limits, and persistent
  revocation tombstones.
- No offline queue/backfill; fan-out snapshots only currently trusted peers.
- Separate local and remote clipboard entry points plus pasteboard change-count
  tokens; a remote clip has no outbound call path.
- Existing pasteboard type polling remains in place for Universal Clipboard and
  Handoff lazy materialization.
- V2-only discovery and HELLO capabilities, with V1 envelopes rejected as
  incompatible and V1 trust/pending/revocation files retained but never used
  to authorize V2.
- Bounded PNG/JPEG BEGIN/ready/chunk/commit transfer, per-connection sender and
  receiver state, strict hashes/order/signatures, private partial files,
  decoder pixel/memory limits, timeout/abort/disconnect cleanup, and redacted
  diagnostics.
- Per-peer, default-off `allowsOutgoingImages` persistence and gear menu. The
  setting gates only locally originated outgoing images; incoming images do
  not consult it and enter the same received-from-sync loop guard as text.

## Requires the independent peer implementation

- macOS-initiated and peer-initiated real LAN pairing and clipboard transfer.
- Pin-change/MITM negative test across the two products.
- Online/offline revocation delivery and restart recovery across both products.
- Two-connection convergence and the three-device one-hop network-log test.
- Sleep/wake, WLAN transition, latency, and sustained-load measurements on a
  representative cross-platform network.
- Bidirectional PNG and JPEG transfers at representative and 16 MiB boundaries
  against the independent Python SRC, including mid-transfer sender cancel.
