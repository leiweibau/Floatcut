# V3 JSON schemas

Draft 2020-12 schemas are independently versioned from v2. Each schema has a
stable `$id`; relative references resolve within this directory.

`message.schema.json` validates the control channel. `data-channel.schema.json`
validates `FILE_OPEN`, `FILE_READY`, and pre-READY `ERROR` on the separate TLS
data channel. Whether an ERROR is legal at that point remains a state check.
Binary DATA/END records are specified by the normative protocol and represented
by the [v3 fixtures](../../fixtures/v3/README.md).

Only fields belonging to the selected message type are constrained. Unknown
fields are ignored, including a field that has meaning for a different message
type. Envelope fields and identities shared by all branches remain constrained.

JSON Schema does not express the complete wire contract. A strict JSON parser
must reject duplicate keys, floats, exponent notation, non-finite values,
invalid UTF-8, lone Unicode surrogates in strings or keys, and container nesting
beyond eight before schema validation. Scalar leaves do not add a nesting level.
Implementations must additionally validate UTF-8 byte limits, capability sort order, NFC names,
decoded sizes/hashes, arithmetic relationships, authenticated identities,
state/order, and timeouts. Nonce patterns include canonical base64url zero pad
bits; they require exactly 32 decoded bytes without padding.
Canonical-field patterns require the actual end of the string, including when
the input ends with a newline; the regex `$` anchor alone is insufficient.

The schemas describe fully valid profile messages and do not classify the wire
response to an invalid offer. Follow the normative receive pipeline: framing
and JSON errors come first, then required field types and canonical IDs/hashes.
A well-typed file size above 8 GiB but within `0...2^53-1` receives
`FILE_REJECT/too_large`. An invalid portable basename, NFC or UTF-8 name limit,
or a canonical but wrong target/digest receives `FILE_REJECT/invalid_offer`,
including cases rejected by the full schema. A Trusted peer without the
negotiated file capability receives `FILE_REJECT/unsupported`. Full schema
validation alone cannot select these responses.
