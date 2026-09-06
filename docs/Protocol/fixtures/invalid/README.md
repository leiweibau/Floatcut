# Invalid fixture classes

The checked-in `.frame` files cover zero and oversized lengths, truncated
prefix/payload, invalid UTF-8, duplicate JSON keys, nesting depth 9, an
unsupported protocol version, and a mismatched clipboard hash. They are
generated deterministically with `Scripts/generate-sync-fixtures.sh`.

State-dependent negatives (clipboard before `HELLO`/trust, noncanonical UUID,
non-zero hop count, replay, and altered TLS identity) are exercised by each
platform's state-machine or integration harness because they require an
authenticated connection context rather than framing alone.
