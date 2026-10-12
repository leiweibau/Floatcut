# V3 contract vectors

These fixtures supplement [the normative v3 contract](../../floatcut-sync-v3.md).
They are wire examples and independently reproducible byte vectors. The Python
client in `src/floatcut_sync_ref` still implements v2; these fixtures do not
claim that a v3 runtime exists.

- `pairing-vectors.json`: TCP-role control binding, both role-bound nonce
  commitments, the complete transcript, and the six-digit comparison code.
  Every UUID is serialized as its 16 RFC-4122 network-order bytes. Every hash
  input is included as hex so implementations can compare inputs before hashes.
- `file-transfer.json`: a directed `report.txt` offer for the bytes `61 62 63`
  (`abc`), its manifest hash, control exchange, data-channel JSON, and binary
  record offsets. It identifies separate control and data message arrays.
- `file-open.frame` and `file-ready.frame`: four-byte big-endian length plus
  compact UTF-8 JSON. These frames precede the binary stream; they are not part
  of `file-data.bin`.
- `file-data.bin`: a 16-byte DATA record followed by a 45-byte END record.
  DATA contains opcode `01`, length `0000000b`, offset `0000000000000000`, then
  `61 62 63`. END contains opcode `02`, length `00000028`, final size as U64BE,
  then the complete SHA-256 as 32 raw bytes. `file-content.bin` is the resulting
  three-byte file.
- `binary-boundary-vectors.json`, `empty-data.bin`, and `two-chunk-data.bin`:
  zero-byte END-only transfer and one complete 262,144-byte chunk followed by
  a one-byte final chunk. The second chunk starts at offset 262,144.
- `clipboard-update.json`, `clipboard-update.frame`, and `image-transfer.json`:
  preserved v2 clipboard shapes under the v3 envelope.
- `control-messages.json`: rejection, cancellation, receipt, pairing-rejection,
  keepalive, revocation, error, and image-abort examples. It is an example
  collection, not a single chronological session.
- `progress-messages.json`: receiver-authored initial, periodic and committing
  byte counters bound to the accepted three-byte offer. Relative event times
  are fixture annotations, not wire fields. Periodic progress is at most once
  per second; the mandatory committing event can follow immediately after a
  periodic event. Percentage vectors use integer floor and distinguish an empty
  file before/after valid END. A 100% counter does not mean `saved`.

`invalid/schema-messages.json` contains messages rejected by the full profile
schemas and names the schema that must reject each. This includes well-typed
values above a profile limit or with an invalid basename; the normative receive
pipeline determines their wire responses before full schema validation.
`invalid/semantic-messages.json` contains
messages that pass JSON Schema but fail a named semantic constraint: UTF-8 byte
counts, NFC, sorted capabilities, authenticated target identity, or manifest
hash. `invalid/*.frame` covers length, truncation, UTF-8, duplicate keys,
non-integer lexical forms, and JSON depth. `invalid/data-streams.json` names
malformed binary streams and their offered size/hash.

`invalid/sender-streams.json` identifies bytes sent after a valid END. These
violate the sender contract; the receiver accepts the first valid END and closes
without processing the tail. They are deliberately separate from streams that
require receiver rejection. JSON depth counts containers only; scalar leaves
add no level. Negative Unicode vectors include lone surrogates in values and
keys; a valid escaped surrogate pair decodes to one Unicode scalar.
`invalid/progress-sequences.json` covers regressing counters and phases;
progress semantic vectors also exceed the accepted byte budget or count an
incomplete DATA record. The counters describe validated, successfully written
records and never sender-side socket writes.

Run `python -m pytest tests/test_v3_contract.py` with the repository's development
dependencies installed. These contract checks validate all schemas and local
references, reproduce each cryptographic input and hash, preserve wire framing,
and reject the negative vectors. State transitions, operating-system file
publication, TLS behavior, cancellation races, and timeout handling still
require the implementation conformance checks.
