# Floatcut Sync v1 conformance

Both platform agents MUST record a passing result for every item before v1 is
declared interoperable.

- [ ] Reads and writes the four-byte big-endian framing fixtures.
- [ ] Rejects zero, oversized, truncated, duplicate-key, invalid-UTF-8, and
      over-nested frames before application dispatch.
- [ ] Produces pairing hash `36794c...55e1` and code `919012`.
- [ ] Uses `_floatcutsync._tcp` and the exact TXT keys/capability.
- [ ] Advertises `pair=0` when new pairing is disabled, rejects a new
      `PAIR_REQUEST` with `pairing_disabled`, and keeps existing Trusted peers
      and resumable pending handshakes functional.
- [ ] Uses mutual TLS 1.3 and validates the required P-256 certificate profile.
- [ ] Pins full certificate SHA-256 after explicit two-sided confirmation.
- [ ] Keeps a matching simultaneous `PAIR_COMPLETE` idempotent after entering
      `Trusted`; the paired channel remains online.
- [ ] Resumes `PAIR_STATUS: complete` after reconnect with the same pin,
      including a peer that already compacted its completed pending record.
- [ ] Rejects changed identity without an override path.
- [ ] Preserves Unicode and CR/LF byte-for-byte through JSON UTF-8.
- [ ] Enforces 524,288-byte content and 1,048,576-byte frame limits.
- [ ] Never sends clipboard data before `Trusted`.
- [ ] Never forwards a received clip, including with deduplication disabled.
- [ ] Has no persistent send queue or reconnect backfill.
- [ ] Enforces ten paired peers and persistent revocation tombstones.
- [ ] Passes macOS-to-platform and platform-to-macOS pairing and clipboard tests.

Platform/API mapping and unavoidable limitations belong in `docs/PLATFORM_NOTES.md`.
