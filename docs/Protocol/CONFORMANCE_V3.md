# Floatcut Sync v3 conformance

Status: required acceptance cases, not a record of passing native clients.
[`floatcut-sync-v3.md`](floatcut-sync-v3.md) is the normative wire contract and
[`V3_IMPLEMENTATION.md`](V3_IMPLEMENTATION.md) supplies native execution/storage
requirements. The Python runtime remains v2. Passing its existing tests does
not establish v3 pairing, TLS, file publication, or Windows/macOS interoperability.

An implementation is conformant only when every applicable case below passes.
Record unsupported/not tested separately from passed. The optional
`file.transfer.v1` capability requires all file cases before advertising it;
a v3 clipboard-only client must pass the common cases and reject file offers
as specified. A platform API mapping or successful build is insufficient.

## Evidence to record

For each test record client commit, OS version, native TLS backend, filesystem
and destination type, direction, UUID ordering, addresses/interface scope,
fixture IDs, and outcome. Network cases require redacted logs from both
implementations. Use deterministic virtual clocks, controllable transport and
disk workers for race/timeout cases; use real native TLS/filesystems for API
behavior; use independent Windows and macOS products for the LAN matrix.
Fixtures under [`fixtures/v3`](fixtures/v3) are common byte inputs, not
substitutes for state-machine tests. Hash/UUID calculations must not use one
implementation's serializer as the expected result for another.

## Common v3 requirements

- [ ] Publish `pv=3`, strict canonical values and lower-case TXT keys; accept
      ASCII-case variants of keys, reject case-insensitive duplicates, and
      treat DNS case/final-root-dot variants as the same observation.
- [ ] Require the three clipboard capabilities, accept valid sorted unique
      capability supersets, enforce the shared capability count/name bounds,
      and treat current authenticated HELLO capabilities as authoritative,
      accepting an advertisement's stale capability snapshot. A peer lacking
      `file.transfer.v1` stays eligible for clipboard sync.
- [ ] Negotiate exactly `floatcut-sync/3` for normal channels. Reject missing,
      wrong or unexpected ALPN before application parsing; reject v1/v2
      envelopes and do not silently downgrade an intended v3 connection.
- [ ] Use a full mutual TLS 1.3 handshake with the common certificate profile,
      persistent identity, SAN binding and full-DER SHA-256 pin. Disable early
      data and resumption. An OS trust-store success is insufficient.
- [ ] Preserve intended target device ID/pin from discovery/user selection
      through TCP, TLS and HELLO; a valid certificate for peer B at peer A's
      endpoint must never produce a pairing prompt or trust for B.
- [ ] Pass strict UTF-8/JSON framing fixtures, including fragmented/coalesced
      frames, integer syntax, duplicate keys, depth limit, zero/oversized length
      and EOF with a partial prefix/payload. Preserve Unicode and line endings
      without normalization in clipboard content.
- [ ] Reproduce all v3 commitment, pairing transcript, comparison-code,
      control-binding and file-offer hash vectors byte for byte, using UUID
      network-order bytes and unsigned big-endian integers.
- [ ] Require both commitments before revealing contribution nonces; verify
      every reveal against its role/request/identities/commitment. A changed
      contribution, wrong role or premature reveal cannot produce a code or
      trust. A transport retry cannot create a second commitment for the same
      retained request after a contribution was revealed.
- [ ] Persist each local user's confirmation independently. Resume from
      `awaiting_confirmation` never sends or records local `confirmed` without
      that local user's decision. Repeated matching status/completion messages
      are idempotent and cannot extend expiry.
- [ ] Enforce at most 32 persisted peer records through serialized reservations
      and commit checks; include offline/disabled peers. Overlapping pairings
      cannot create a 33rd. Cancellation/removal restores capacity.
- [ ] Revocation invalidates all old pairing generations, pending completion
      authority, current clipboard/file authorization, and stale worker/UI
      callbacks before transport shutdown. Retained resume material cannot
      remove a tombstone or establish trust after revocation.
- [ ] Restore retained pairing deadlines across app restart only with the same
      proven boot generation/clock representation and original elapsed deadline.
      Same-boot restart at t=100 seconds leaves at most 20 seconds from a
      120-second request; wall-clock changes cannot renew it. A changed/missing
      boot proof, clock rollback or expiry invalidates the context, retaining
      already persisted peer trust. Completed retention is likewise fixed from
      its first completion, rather than from restart/status receipt.
- [ ] Pass v3 text/image boundary and malformed-transfer cases, including
      terminal image rejection before DATA, exact chunk/byte budgets, hash and
      media-signature checks, cleanup and no forwarding of remote clipboard.
- [ ] Apply the existing discovery/liveness/ownership requirements as
      explicitly inherited by v3. Normal-channel DATA from file sockets does
      not refresh sync heartbeat or create Online status. Sleep/wake and stale
      callbacks cannot revive expired authorization.

## Control plane and binding cases

Every case must assert that rejection/failure before publication grant leaves
no published file and releases the correct reservation exactly once. Granted
work resolves its actual native outcome and receipt, including a successful
publication after late cancellation. A dropped message is not approval.

| ID | Setup/event | Required observation |
| --- | --- | --- |
| F01 | Send one regular file to selected peer A while B is also Online. | Exactly A receives the offer and its accepted bytes. B receives neither an offer nor bytes; there is no clipboard/history fan-out. |
| F02 | Use valid peer B's endpoint/certificate while A is the selected target. | Connection fails identity binding. No offer to B, no retargeting, no token. |
| F03 | Send an offer before Trusted, on a revocation channel, with wrong target, or with a wrong recomputed offer hash. Run separately. | No decision dialog, acceptance or temporary payload file. Common protocol rejection follows the contract. |
| F04 | Omit `file.transfer.v1` locally/remotely, then disable local file receiving with both capabilities present. | Normal clipboard channel remains usable; file offer receives the defined `unsupported` or `disabled` rejection and sends no file data. |
| F05 | Modify the original source after preparation and before/during send; also replace its pathname. | Offer and bytes still describe the immutable snapshot exactly. No source path, ACL, executable mode or platform stream is transferred. |
| F06 | Replay the same offer with a new message ID, then change the metadata under the same transfer ID. | One reservation/dialog; no deadline extension or hash substitution. Changed metadata is rejected according to the contract. |
| F07 | Accept, then present valid OPEN; subsequently reuse its token on a second TLS connection and race two valid OPENs. | Only one valid OPEN consumes the token and receives READY. No second file writer or second saved file. |
| F08 | Present wrong token, transfer ID, offer hash, control binding, pin, role or trust generation. Run separately. | No READY or accepted DATA. A cross-peer/unauthenticated attempt does not consume the legitimate peer's token. |
| F09 | Lose/reconnect the control stream after acceptance; try the old OPEN over a fresh data stream. | Old token/binding cannot authorize transfer. A new trusted channel permits status query only, with the original offer hash. No automatic byte resume. |
| F10 | Send DATA before READY, JSON messages after READY, FILE_OPEN on sync ALPN, HELLO/pairing on file ALPN, or open a file stream without an accepted offer. | The misplaced stream/message is rejected; no data sniffing, pairing exception or fallback to another channel kind. |
| F11 | Deliver offer decision at t=60 seconds on receiver, delayed local Accept afterward, and sender with no decision through t=90. | Receiver rejects at its fixed decision deadline; stale Accept is ignored; sender cancels at its deadline. Repeated offers do not postpone either. |
| F12 | Valid OPEN reaches receiver before/at/after its 15-second token deadline. Delay READY beyond sender's five-second deadline. | Boundary behavior follows the contract with receiver elapsed time authoritative; stale token/READY cannot restore a terminal transfer. |
| F13 | Reserve four incoming and four outgoing transfers to different peers, attempt fifth per direction; also attempt a second per direction to one peer. Repeat with four outgoing preparation workers held before OFFER. | Reject `busy` without exceeding global/per-peer quotas, including preparation. Existing opposing direction is independent; all nonterminal phases count. |
| F14 | Race accepts, aborts and commit worker completion; repeat cleanup callbacks. | Serialized quotas never exceed bounds; cancellation invalidates old work; slots and receipt reservations release once. |
| F15 | Fill 1,024 unexpired receiver receipt slots, then receive another offer. Expire a slot and repeat. | Reject `busy` before acceptance while full; do not evict a live receipt. Capacity returns after defined expiry. |
| F16 | Lose terminal saved result, reconnect with fresh HELLO nonces and request status using original ID/hash. | Saved result returns for same current authorized peer pin/generation without requiring old control binding; no new transfer/prompt/data. |
| F17 | Request status with wrong hash, peer pin or trust generation; repeat after receipt expiry and after user deletes/moves a saved file. | No cross-peer receipt disclosure. Missing receipt returns `unknown/receipt_missing`, not assumed failure/success. A retained saved receipt remains historical saved. |
| F18 | Fill 1,024 recent never-accepted offer IDs, submit another offer, then expire an entry. Combine duplicate/disabled/full conditions and destination/capacity failures. | Shared admission precedence produces identical reasons on both platforms; full cache rejects busy without early eviction or duplicate deadline renewal. No acceptance after a failed local destination/receipt check. |
| F19 | Stall 32 pre-HELLO/pre-OPEN candidates across both ALPNs, then open one more. | Shared pool never exceeds 32; excess candidate closes and accepted stalled candidates expire after 15 seconds. No file candidate bypass or Online status from accepted TCP alone. |

## Binary data cases

Run these after a valid binding handshake. Feed headers and payloads at every
split position, one byte at a time, and with coalesced adjacent records. Record
whether a negative fixture tests structure alone or the complete offered-file
semantics. The DATA opcode is `0x01`, END is `0x02`, record lengths are U32BE,
offsets/sizes are U64BE, DATA chunks are 262,144 bytes except the exact final
remainder, and END's payload is exactly 40 bytes.

| ID | Input | Required observation |
| --- | --- | --- |
| D01 | Files of 0, 1, 262,143, 262,144, 262,145 and 524,288 bytes, with deterministic arbitrary binary content. | Exact bytes/hashes saved; zero-byte transfer uses END only. Fixed-size and remainder boundaries agree on both platforms. |
| D02 | File of 8,589,934,592 bytes; offer of 8,589,934,593 bytes. | The supported maximum streams with bounded RAM; oversized offer is rejected without staging the payload. A virtual count/hash test alone does not certify a real maximum-size filesystem transfer. |
| D03 | Unknown opcode, zero/oversized DATA length, DATA with no bytes, wrong END length, or huge length prefix. | Reject before allocating from the advertised length or writing payload. No arithmetic overflow, crash or resynchronization scan. |
| D04 | Wrong initial offset, repeated offset, gap, overlapping bytes, descending offset or offset addition overflow. | Fail as invalid data; never seek/write attacker-chosen arbitrary positions. |
| D05 | Short non-final chunk, oversized chunk, extra chunk after declared size or DATA for a zero-byte offer. | Fail before writing bytes beyond the offer budget. Partial file never exceeds the declared size. |
| D06 | END before complete size, missing END, END with wrong total size or SHA-256, truncated header/payload or clean EOF before END. | No publication or false saved result; partial bytes are removed. |
| D07 | Valid END immediately followed by already buffered extra record bytes. Separately send trailing bytes after the receiver closes at valid END. | Sender never produces trailing records. Receiver closes/ignores all following bytes in both cases, without a second transfer or publication and without changing valid completion based on coalescing. |
| D08 | Drip partial record bytes for more than 30 seconds without one complete validated record; then sustain full records just below that bound. | Partial bytes do not refresh idle deadline. Complete valid records do; receipt status/progress reflects verified bytes, not TCP receipt. |
| D09 | Run past two-hour accepted-transfer lifetime; separately block commit preparation through its 30-second deadline. Repeat with a native operation stalled after publication grant. | Expiry forbids ungranted publication. A granted operation is not relabeled failed/cancelled by deadline; it remains committing/unconfirmed until native outcome and receipt resolve. Control traffic continues. |
| D10 | Block receiver disk worker and fill the bounded queue while exchanging text/PING and then cancel/revoke on sync channel. | File buffering remains bounded; sync stays responsive and never marks saved. Authorization invalidates before delayed disk completion. |
| D11 | Force partial TLS/socket writes, TLS-record fragmentation, coalesced DATA, and TLS 1.3 post-handshake traffic. | Application record order/offset remains exact; transport boundaries/key updates neither duplicate nor drop file bytes nor reset state. |

## Filesystem, filename, and crash cases

Run native tests on every advertised supported destination filesystem. A
filesystem failing private staging, same-filesystem no-replacement publication
or the required durability sequence is reported unsupported and rejected before
acceptance; it is not silently treated as conformant through a copy fallback.

| ID | Setup/event | Required observation |
| --- | --- | --- |
| S01 | NFC names at 1 and 180 UTF-8 bytes, including multibyte and supplementary characters. | Offer hash uses exact UTF-8 bytes; default final leaf is exactly `<transfer_id>-<file_name>`. Unicode display/count differences do not change identity. |
| S02 | Empty name, 181-byte name, non-NFC text, C0/DEL, `/`, `\\`, `:`, `<`, `>`, `"`, `\|`, `?`, `*`, `.`, `..`, trailing dot or trailing ASCII space. | Reject name semantically; never silently normalize/truncate it. Include path, UNC, drive and alternate-stream-shaped inputs. |
| S03 | Sender names resembling Windows device names; case/normalization-equivalent destination names; filesystem unable to represent the default leaf. | Default UUID prefix remains a leaf. User alternative is validated locally before acceptance; unsupported destination rejects explicitly. No implicit rename policy. |
| S04 | Existing final regular file, directory or symlink/reparse target; separately create the destination during transfer. | Exclusive publication fails with `destination_exists` without replacement; existing contents remain exact. No exists-then-overwrite race or silent suffix choice. |
| S05 | Destination/staging directory replaced with a symlink/reparse point during receive, revoked sandbox directory grant, or staging on another filesystem. | No traversal outside retained local authority, visible copy fallback, or unexpected destination. Fail/clean up unpublished work. |
| S06 | Observe destination during receiving/commit from another process; inspect temporary permissions/ACLs. | Final path is absent until complete atomic publication; other ordinary users cannot read private bytes. Staging names are random and not derived from remote filename. |
| S07 | Disk full, quota exhaustion, failed write/flush, failed prepared-journal write, or no rename permission before publication. Run each failure point. | No saved response, private cleanup, existing files untouched and correct terminal failure. No claim of complete reception from successful hash alone. |
| S08 | Cancel/revoke immediately before publication grant; separately cancel after grant before the native operation completes and after successful publication. | First ordering forbids final file. Second returns pending/committing until actual outcome/receipt; final file is never deleted or saved relabeled cancelled. Granted old worker may resolve only its own journal/receipt after fresh engine/pairing, never restore peer authority. |
| S09 | Crash before prepared journal, after flushed prepared record/before publication, after publication/before saved receipt, and after saved receipt/before result. Repeat with a pre-existing final file having identical bytes but a different file identity. | Startup resolves each stage before classifying terminal status. No byte resume. Prepared stage becomes saved only after the final file has the same stable staging-file identity and exact size/hash; identical foreign collision cannot become saved. |
| S10 | Fail receipt persistence after successful publication; reconnect/status-query and restart. | Cannot report failed/cancelled or retry bytes as a new delivery. Prepared evidence remains until durable saved recovery succeeds. Sender shows uncertainty while receipt is unresolved. |
| S11 | Alter/delete destination before recovery of a prepared record; separately after an already durable saved receipt. | Prepared evidence alone cannot falsely become saved. Durable saved receipt remains historical saved despite later user file changes. |
| S12 | Deliver same terminal/status messages repeatedly, restart with retained receipt, or retry a new explicit send using a fresh transfer ID. | No duplicate saved file from replay. A fresh explicit send is a new transfer and requires its own acceptance. |
| S13 | Send executable-looking bytes, archives or arbitrary unknown file formats. | Treat as opaque bytes; never open/execute/extract/import into clipboard or forward automatically. Receiver permissions/security metadata are local, never sender supplied. |

## Shared transfer UI and progress cases

Use the same state/view model contract on both platforms; these cases do not
require pixel-identical windows. A test must inspect both the engine state and
the visible label/action outcome.

| ID | Setup/event | Required observation |
| --- | --- | --- |
| U01 | Start Send while snapshot/hash worker is held, then release it. | Selected peer/file remain stable; preparing is indeterminate, then waiting for approval. Sender does not show remote byte progress before receiver progress. |
| U02 | Incoming offer; choose destination and Accept, then repeat with Reject and with no decision. | Same transfer-window component displays authenticated sender/name/size and explicit consent. Reject sends no bytes; no-decision expires. A delayed old Accept cannot revive the offer. |
| U03 | Reorder display-name/peer rows or select B while an A preparation/offer callback is delayed. | Transfer window still belongs to A's canonical ID/pin and transfer ID, never the row index or current selection. |
| U04 | READY, several valid DATA records and valid END with throttled progress. | Receiver queues initial `receiving/0` before READY; sender accepts it even if it arrives first. At most one intermediate progress per second and an update in each second of advancing completed bytes; END sends `committing` immediately. No progress is issued on the file stream. |
| U05 | Delay receiver writes while sender socket writes finish. | Sender remote percentage does not exceed authenticated receiver `received_bytes`; successful local send callback never reports saved. |
| U06 | Nonempty file reaches complete byte count but hold hash/flush/publication; repeat with empty file. | Nonempty percentage uses integer floor and can show 100 while `Wird gespeichert und geprüft`; empty is zero until END then 100. Neither is successful until matching durable saved result. |
| U07 | Wrong progress author/hash/ID, decreasing count, count above offered size, count between legal chunk boundaries, invalid phase or progress arriving after terminal result; repeat identical valid progress. | Reject invalid progress according to contract; identical repeated progress is harmless and does not renew deadlines. No percentage overflow, different-peer update, reopened terminal window or saved-to-receiving regression. |
| U08 | Explicit Cancel from each side during preparing/offered/accepted/receiving; enter committing and inject delayed CANCEL before and after publication grant. | Committing disables Cancel in both UIs. A stale cancel before grant invalidates work; after grant receives pending/committing until actual native outcome, without false cancellation or final-file deletion. |
| U09 | Hide/close window during decision/receive and reopen transfer list; deliver stale epoch/revision UI callbacks afterward. | Window dismissal does not automatically accept, cancel, mark saved or lose transfer ownership. Current state returns; stale snapshots cannot overwrite it. |
| U10 | Lose saved result after END, wait past 45-second result deadline and reconnect. | Sender displays unconfirmed and performs read-only status recovery; no automatic resend. Saved/pending/unknown answer updates the same transfer view truthfully. |

## Independent native interoperability matrix

Run every row with Windows sending to macOS and macOS sending to Windows, and
with sender UUID smaller and larger than receiver UUID. Use native identities
from each product, not two instances of the same TLS/codec implementation.

| Matrix case | Required measured result |
| --- | --- |
| Normal control plus file on one published SRV port | ALPN routes two full mutual TLS 1.3 streams correctly; one trusted Online peer; file sender dials in both UUID orderings. |
| Empty, one-byte, exact chunk, remainder, representative large and maximum-size files | Exact saved size/SHA-256 and bounded memory, responsive clipboard/PING, no additional discovery service or file payload in control JSON. |
| Unicode names and device names | Same offer/binding hashes and saved bytes across UTF-8/UTF-16 platforms; supported local leaf handling conforms to S01–S03. |
| IPv4, IPv6 global and scoped link-local; multiple adapters | Current SRV endpoint and scope honored with no security fallback or retargeting. |
| User reject, timeout and cancel in every phase | Same terminal interpretation and cleanup; no file after cancellation before publication grant; already granted native work reports its truthful outcome. |
| Shared transfer window and receiver-authored progress | Same acceptance/actions/state meanings; progress never treats 100% or local write completion as saved. |
| Local/remote revocation, disable, identity reset and control disconnect | Unpublished work loses authority promptly; old tokens/workers cannot survive fresh channel/generation. |
| Result loss and status query; process crash at publication stages | Exactly one published file and truthful saved/pending/unknown semantics; receipt survives process restart. |
| Sleep/wake, network switch, slow link, disk stalls and loaded clipboard | Monotonic deadlines reconcile before UI publication; sync traffic remains usable; bounds are observed and measured. |

The shared checklist is signed only after independent LAN runs are recorded.
Loopback tests establish native TLS and storage behavior; they do not certify
firewall, local-network permission, interface scope, sleep/wake or independent
client interoperability.
