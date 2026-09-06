# Floatcut Sync v2 conformance

An implementation is v2-conformant only after every applicable item passes.

- [ ] Advertises `pv=2` and the exact sorted v2 `caps` value.
- [ ] Publishes canonical lower-case TXT keys, accepts their ASCII-case variants,
      rejects case-insensitive duplicate keys, and keeps TXT values strict.
- [ ] Treats DNS names with ASCII-case or trailing-root-dot differences as the
      same internal service while preserving their presentation spelling.
- [ ] Rejects v1 envelopes and incompatible DNS-SD advertisements.
- [ ] Passes all unchanged v1 framing, TLS, pairing-state, pinning, revocation,
      topology, replay, and text-transfer requirements with `v: 2`.
- [ ] Produces pairing hash `ab448a...9ad5` and code `395736`.
- [ ] Accepts valid PNG and JPEG transfers at chunk boundaries and at the
      16,777,216-byte maximum.
- [ ] Waits for `CLIPBOARD_ACK/ready` before sending chunks.
- [ ] Rejects out-of-order, missing, duplicated, short non-final, oversized,
      bad-base64, bad-chunk-hash, bad-total-hash, and bad-signature transfers.
- [ ] Allows at most one incoming and one outgoing image per connection.
- [ ] Publishes only after commit by atomic rename and removes every partial
      file after abort, failure, or disconnect.
- [ ] Never sends clipboard data before `Trusted` or on a revocation channel.
- [ ] Never forwards a received text or image clip.
- [ ] Does not retain image bytes in logs, peer stores, pairing stores, or
      revocation stores.
- [ ] Passes PNG and JPEG transfers in both directions with an independent
      implementation, including Unicode device names and IPv4/IPv6 transports.
