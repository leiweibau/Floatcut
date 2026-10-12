# Floatcut Sync v3: native implementation requirements

Status: implementation requirements for the v3 contract; no native client is
declared conformant by this document. The running Python CLI remains v2 until
its runtime is upgraded. The normative wire contract is
[`floatcut-sync-v3.md`](floatcut-sync-v3.md); schemas and fixtures under
`schemas/v3` and `fixtures/v3` are shared inputs for every platform. Where a
wire field, byte layout, timeout, or state transition is concerned, that contract
takes precedence. The requirements below fix the execution and storage
behavior needed to implement it safely and consistently. Native APIs are
implementation mappings, not additional protocol variants.

## I1. One authority for state and publication

An implementation MUST have one serialized executor for peer authorization,
normal-channel ownership, pairing reservations, transfer reservations, token
consumption, deadlines, and publication decisions. A serial dispatch queue,
actor, or locked transactional engine is acceptable; concurrent callbacks that
mutate separate dictionaries without one transaction are not.

Every asynchronous operation MUST carry `engineEpoch`, `peerGeneration`,
`controlConnectionID`, `transferID`, and a transfer lifetime token where
applicable. File hashing and disk I/O run on workers. Workers return immutable
results to the serialized executor and MUST NOT directly send terminal success,
mark a peer Online or consume an acceptance token. A worker may publish a final
file only with the one-shot publication grant described below. The
executor checks every ownership value again before acting. Disabled sync,
identity reset, or an engine replacement increments the engine epoch; peer
disable/revocation increments the peer generation. A stale completion can
perform only idempotent cleanup of the private file it owns, except that an
already granted publication must finish or reconcile its actual native outcome
and private journal/receipt. That exception never recreates peer authorization,
marks the old peer Online, or mutates a new engine's trust state.
The callback/connection `peerGeneration` is distinct from the persistent local
trust generation used by receipts: temporarily disabling a still-paired peer
invalidates live work but does not manufacture a new pairing or erase its
historical receipt authorization after it is enabled again.

User choice MUST be captured as a canonical device ID and its current stored
DER certificate pin before opening a connection or reading the source file.
Device names and UI row indexes never authorize a destination. A discovery
refresh MUST NOT retarget an already selected transfer. A source-worker result
for peer A cannot become an offer to peer B after the user changes selection.

Publication permission and cancellation have one linearization order on this
executor. After complete validation, file flush and prepared-journal flush,
recheck authorization, control-channel identity, lifetime and deadlines. Then
issue exactly one irrevocable **publication grant** containing the retained file
and destination identities, offer identity, receipt ownership and generation.
Cancellation/revocation before the grant forbids publication. Dispatch the
granted atomic no-replacement operation to a file worker; no blocking rename,
copy, hash or flush runs on the control executor.

After the grant a native operation may already be in progress and cannot be
reliably cancelled. Do not revoke that grant, delete a published final file,
or claim cancellation/failure merely because a timer or revocation occurred.
Resolve its actual native success/failure and persist the receipt before
reporting saved. A late CANCEL while it is unresolved receives
`FILE_RESULT/pending` with `phase:committing`. A native failure such as
`destination_exists` remains a truthful failure; a grant itself is never saved.
Engine shutdown/replacement must drain granted work or retain exclusive journal
ownership for recovery before a new engine begins file recovery. Control and
clipboard on a new epoch need not wait for blocking disk operations.

## I2. Two independent TLS streams at one advertised port

Use the current DNS-SD SRV endpoint and port for both channel kinds. The
listener supports `floatcut-sync/3` and `floatcut-file/1`. Each outgoing attempt
offers exactly the ALPN for its intended channel. Route an accepted connection
by the **negotiated** ALPN before decoding any application bytes. Missing or
wrong ALPN closes the connection; the first bytes are never sniffed to choose
JSON versus binary decoding.

Both streams require mutual TLS 1.3, the same persistent identity, and the
contract's certificate profile/SAN/full-DER pin checks. A valid TLS connection
on the file ALPN alone grants no file permission. It can only attempt the
binding handshake for a current locally accepted offer. An unpaired
certificate MUST NOT open a pairing prompt through the file channel. The
normal-channel HELLO and data-channel binding checks must use the identity
authenticated by the TLS stack, rather than trust a peer ID supplied by JSON.
Disable TLS early data and session resumption for both kinds of v3 channel;
the file channel must authenticate the current certificate and pin through a
full handshake. Do not use a ticket from the normal channel as file-channel
authorization.

The data sender dials the receiver even if the sender has the larger UUID.
The smaller-UUID rule continues to govern established normal sync channels.
This difference is explicit, and both UUID orderings MUST be tested. The data
connection does not create a second Online entry or replace a normal-channel
slot. Closing it must not trigger normal-channel reconnect.
Use one shared pre-HELLO/pre-OPEN candidate reservation pool with at most
32 sockets across both ALPNs. Excess candidates close immediately; every
accepted candidate receives a 15-second establishment deadline. A file
candidate cannot bypass this pool because an offer was accepted.

TLS sessions and socket callbacks MUST be separate objects per connection.
Do not share one mutable stream buffer, pending write queue, TLS context, or
parser between sync and file channels. An ALPN result cannot be inferred from
an application's requested ALPN. Ordinary TLS 1.3 control records, such as a
key update, are transport work and MUST NOT reset the application's offset,
transfer reservation, deadlines, or identity binding.

HELLO's authenticated capabilities are authoritative. A stale DNS-SD capability
snapshot cannot by itself reject an otherwise valid peer; use the intersection
of the two current HELLO lists for file permission. An unknown capability is
inert unless an explicit shared contract defines its behavior.

### macOS mapping

Configure `NWListener` and `NWConnection` with `NWProtocolTLS.Options` and the
persistent `SecIdentity`. Add the accepted application protocols with
`sec_protocol_options_add_tls_application_protocol`. Set both TLS version
bounds to 1.3. Require the peer certificate on the listener explicitly:
Apple documents that server-side peer authentication defaults to false.
[ALPN configuration](https://developer.apple.com/documentation/security/sec_protocol_options_add_tls_application_protocol(_:_:)),
[mandatory peer authentication](https://developer.apple.com/documentation/security/sec_protocol_options_set_peer_authentication_required(_:_:)).

Perform profile, self-signature, SAN, and pin validation in
`sec_protocol_options_set_verify_block` on a non-UI queue. Complete each
verification callback exactly once, including cancellation. The callback may
not approve every self-signed certificate and defer the actual pin check until
after file bytes are processed.
[Verification callback](https://developer.apple.com/documentation/security/sec_protocol_options_set_verify_block(_:_:_:)).

Read the negotiated application protocol from the TLS metadata after TLS is
ready. Use `sec_protocol_metadata_copy_negotiated_protocol` when available and
free its returned C string after making an owned copy. On older supported
systems use the deprecated `get` accessor with an immediate owned copy;
neither a nil value nor a metadata-access failure is a successful negotiation.
The availability branch changes memory management only, never acceptance.
[Copy accessor](https://developer.apple.com/documentation/security/sec_protocol_metadata_copy_negotiated_protocol(_:)),
[older accessor](https://developer.apple.com/documentation/security/sec_protocol_metadata_get_negotiated_protocol(_:)).

### Windows mapping

Use one Schannel context per socket. Supply the ALPN list through a
`SECBUFFER_APPLICATION_PROTOCOLS` input buffer during context establishment.
After handshake completion, query `SECPKG_ATTR_APPLICATION_PROTOCOL` with
`QueryContextAttributesW`. Require successful ALPN negotiation and compare
`ProtocolIdSize` plus that exact number of bytes to the expected ASCII ALPN;
`ProtocolId` is a byte string, not a guaranteed NUL-terminated string.
[ALPN input buffer](https://learn.microsoft.com/en-us/windows/win32/api/sspi/ns-sspi-secbuffer),
[negotiated result](https://learn.microsoft.com/en-us/windows/win32/api/sspi/ns-sspi-secpkgcontext_applicationprotocol).

Configure TLS 1.3 and mandatory client authentication on accepted sockets,
obtain the actual peer certificate from Schannel, and apply the common profile
and pin verifier before permitting binding. A Windows trust-store success or
a display-name match does not substitute for the protocol's pinned identity.

Permit at most one encryptor and one decryptor for a context; serialize each
direction's application I/O. Handle `SECBUFFER_EXTRA`, empty plaintext results,
partial socket writes, and post-handshake `SEC_I_RENEGOTIATE` through the
Schannel negotiation loop on the same context. Recheck version, ALPN, and
identity after that loop before releasing queued application data. A TLS 1.3
post-handshake event is not a new Floatcut connection or resumed file transfer.
[Schannel decryption and post-handshake handling](https://learn.microsoft.com/en-us/windows/win32/secauthn/decryptmessage--schannel).

## I3. Framing, bounded work, and independent control progress

Maintain explicit prefix/header/payload parser state. TCP reads, TLS records,
and native receive callbacks do not define Floatcut frames. A read may contain
one byte, several frames, or the end of one frame plus the beginning of another.
Validate the complete frame's declared length and field constraints before
allocating payload memory. EOF in a partial frame fails that transfer. Do not
search later bytes for a plausible header to recover from corruption.

Loop around partial reads and writes; retain the unsent suffix until it is
accepted or the channel ends. Advance sent offset only once for each complete
payload submitted in wire order, and advance received offset only after the
corresponding validated payload is written successfully. Use checked unsigned
64-bit arithmetic for sizes, offsets, and additions on every platform. Convert
to platform buffer-length types only after checking the bound. Unicode byte
length is measured from encoded UTF-8, not `String.count`, UTF-16 units, or
display columns.

The full file MUST NOT be loaded into RAM. Use incremental SHA-256 and bounded
read/write buffers. The file worker does not hold the shared state lock during
blocking I/O. Each file channel retains at most one DATA payload of 262,152
bytes in its application receive buffer and one in its application send
buffer, each with its five-byte binary header, plus one JSON prelude of at most
16,384 bytes with its four-byte prefix. These budgets include queued and
in-progress application payloads: handing a record to a worker is not
permission to retain a second one. Bound receive requests to at most 64 KiB
and the remaining current record budget; issue the next only after capacity
is available. TLS/socket-library buffers are separate bounded transport
resources. This local backpressure does not extend the idle deadline.

Do not send DATA until the binding reply authorizes it. The sender streams
the prepared immutable source, not its original pathname. Receiver disk work
preserves DATA order. Disk completion from a retired transfer cannot write
into a replacement transfer's temporary file.

The sync channel's control parser, PING/PONG deadlines, cancellation processing,
and clipboard handling MUST continue while file workers are hashing, writing,
or applying local backpressure. A DATA packet on the file stream is not a
heartbeat on the sync stream. Tests must inject blocked disk I/O and verify
that a sync-channel cancel or revocation invalidates the transfer immediately
on its executor without waiting for that disk operation to finish. Cleanup may
wait until the owning worker relinquishes its handle; that wait never restores
publication authority.

## I4. Source snapshot and regular-file boundary

Resolve the user-selected source locally, open a regular file, and prepare an
immutable private snapshot before emitting an offer. Symlinks, directories,
packages requiring directory recursion, devices, named pipes, and virtual
streams are outside this file-transfer profile. A cloud placeholder must first
be completely materialized by the platform; a hydration failure is a local
preparation failure.

The offer size and hash MUST describe the bytes in the snapshot. Streaming
uses that same retained snapshot handle. A stable open handle alone is not an
immutable snapshot on a filesystem where another process can modify the file.
If a copy or clone is used, restrict write access to the snapshot and ensure
the copy is complete before hashing. Rechecking only source size and mtime is
not a substitute. Cancelled preparation releases its reservation and deletes
its snapshot. Original source paths and snapshots never cross the wire.
Reserve an outgoing slot before preparation begins; preparation counts toward
the global and per-peer outgoing quotas even before a control offer exists.

## I5. Destination authority and no-overwrite publication

The receiver chooses its destination directory and name locally before
acceptance. The sender's `file_name` is an untrusted suggested **leaf name**,
not a destination path. The contract's filename algorithm supplies the initial
suggestion; the user's locally chosen final leaf is still validated by the
platform. Never concatenate a remote field into a path and then normalize it
after opening. Never derive the staging path from the supplied name.

The default final leaf is exactly `<transfer_id>-<file_name>`; this adds the
canonical 36-character UUID and one hyphen to the validated maximum 180-byte
UTF-8 name. If that leaf is not supported by the chosen filesystem, use an
explicit locally chosen alternative before acceptance or reject with
`unsupported_destination`. The receiver MUST NOT silently truncate or
normalize the offer's name or hash input.

Resolve and retain the chosen directory's identity/handle. Create a private
random staging directory on the **same filesystem** as the destination, with
no symlink/reparse traversal and no access for other ordinary local users.
Create a fresh regular temporary file exclusively only after a valid OPEN
claims the token. macOS uses directory mode
0700 and file mode 0600 with inherited ACLs checked/removed as needed. Windows
uses an explicit protected DACL allowing the current user and required system
principals; a permissive inherited directory ACL is insufficient. File data
permissions are locally assigned. Do not preserve sender owner, ACL, executable
bits, timestamps, resource forks, alternate data streams, or extended
attributes.

Before publication, validate exact byte count and total SHA-256, flush file
contents to the platform's file API, and apply any required local received-file
security metadata. Persist and flush the prepared journal record identifying
the transfer, pins, trust generation, offer hash, exact destination, byte size,
content hash, and stable identity of the exclusively created staging file before
beginning atomic publication. This identity is POSIX device plus inode on
macOS, and Windows volume plus file ID. Retain and check the original file
handle; an attacker-selected or stale pathname is not evidence of its identity.
Recheck I1 ownership/authorization/deadlines, grant publication once and dispatch
it to the worker. Publish with one same-filesystem atomic
**no replacement** operation. A prior `exists()` check
followed by an overwriting rename is forbidden. A collision that appears during
transfer is terminal `destination_exists`; do not overwrite, silently choose
another name, or reopen an acceptance dialog within the existing transfer.

If the selected filesystem cannot provide exclusive private staging and atomic
no-replacement publication, refuse acceptance with `unsupported_destination`.
Do not fall back to copying into the visible final filename. On publication failure remove
staging, report failure, and leave any existing destination untouched. After
successful publication remove the private staging directory; cleanup never
deletes the final file.

After publication, persist and flush the `saved` receipt, then send
`FILE_RESULT/saved`. `saved` means complete validated bytes were flushed,
exclusively published, and recorded durably through the supported native APIs.
It does not promise survival of power loss on filesystems that cannot provide
that guarantee. Do not require a POSIX directory `fsync` API on Windows; record
the tested native durability sequence for each supported OS/filesystem. A
post-publication receipt-write failure MUST NOT become `failed` or `cancelled`:
retain the prepared record, reconcile publication, and report uncertainty until
the receipt can be durably completed. Report local success only after the
durable receipt and remote success only after the receiver's terminal result.
TCP/TLS write completion, complete DATA receipt, and a successful hash comparison
alone are not delivery success.
Never automatically open, execute, extract, import into clipboard, or forward a
received file.

On startup reconcile prepared entries before reporting a terminal result. A
prepared entry may become `saved` only after verifying the published regular
file's **same stable identity**, exact size and SHA-256 at its recorded
destination. An existing different file with identical bytes is a collision,
not evidence that publication succeeded. A retained `saved` receipt records
historical successful delivery: the user's subsequent move or
deletion of that file does not change it to failure. Private uncommitted bytes
are removed; data transfer never resumes across a process or channel restart.
Retain terminal receipts for 24 hours with at most 1,024 receiver entries,
reserving a receipt entry before accepting. A status query on a new trusted
control channel uses the same peer/pin/trust generation and original offer
hash; it MUST NOT require the dead control channel's old binding to become
current again. Receipt retention uses wall-clock epoch timestamps; network
timeouts continue to use monotonic elapsed time.

### macOS publication mapping

Retain destination/staging directory file descriptors and use single-component
relative names. Open new staging files with `O_CREAT|O_EXCL|O_NOFOLLOW` and
verify with `fstat` that the result is a regular file owned by the current
user. Flush before publication. Use
`renameatx_np(stagingDirFD, temporaryLeaf, destinationDirFD, finalLeaf,
RENAME_EXCL)`; reject `EEXIST` and unsupported filesystem behavior. Modern
no-follow/beneath flags may additionally be used when supported. Resolving a
directory safely and retaining its descriptor remains mandatory on older
supported systems.
Record `st_dev` and `st_ino` from the retained staging file descriptor and verify
them on the final regular file during prepared-journal recovery.
[Apple fstat identity fields](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/stat.2.html).

Apple's headers expose `renameatx_np` and `RENAME_EXCL`, and its implementation
passes that flag into the rename operation. Ordinary `rename` overwrites an
existing target and is therefore not a permitted fallback.
[Apple rename API definitions](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/bsd/sys/stdio.h),
[Apple rename implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/bsd/vfs/vfs_syscalls.c),
[ordinary rename behavior](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html).

Sandboxed clients retain the user-selected security-scoped directory grant
through preparation/publication and cleanup. If it is lost, fail locally;
never substitute the working directory or a different download directory.

### Windows publication mapping

Open and validate the chosen parent and staging handles, rejecting unexpected
reparse points. Create a new staging file with `CREATE_NEW`, an explicit
private security descriptor, and the access required for write, flush, rename,
and cleanup. Operate on the retained file handle. Call
`SetFileInformationByHandle` with `FileRenameInfo`,
`FILE_RENAME_INFO.ReplaceIfExists=FALSE`, the retained destination
`RootDirectory` handle, and a validated single leaf in `FileName`. Check the
result and final retained handle identity. A generic path move or a
copy-and-delete helper is not evidence of conforming publication.

Use `GetFileInformationByHandleEx(FileIdInfo)` to record the volume serial and
128-bit file ID from the retained staging handle; unsupported identity lookup
means this destination cannot supply the required recovery evidence.
[FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info).

Microsoft documents handle-based rename and failure when replacement is false
and the target exists. Validate atomic visibility and collision handling on
each supported filesystem with the acceptance tests; OS API availability alone
does not establish that a filesystem meets this profile.
[SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle),
[FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info).

## I6. File offer, acceptance, and timer task map

Maintain one explicit transfer object per `transfer_id` with the selected
sender/receiver IDs and pins, control connection ID and binding, offer hash,
byte size/hash/name, local trust generation, current phase, reservation,
deadlines, source or destination handle, receipt reservation, and cancellation
lifetime. Keep the acceptance token only in this object until consumed or
invalidated; never put it into a log, URL, command line, or durable receipt.

| Event | Required native engine action |
| --- | --- |
| Local Send command | Capture target identity/pin, reserve preparation, verify a current eligible trusted v3 control channel and `file.transfer.v1` on both ends, prepare immutable bytes, compute the shared offer hash, durably retain the sent-offer metadata for result/status recovery, then emit one `FILE_OFFER` to that peer. |
| Receive offer | Validate authenticated sender, exact local target, filename semantics, size, recomputed offer hash and current channel binding before allocating or showing UI. Reserve the transfer slot atomically. A duplicate ID is rejected with `duplicate_transfer`, never creates a second prompt or resets a deadline. |
| User accepts | Reserve a durable receipt slot, retain the chosen local destination and private staging authority, then generate a 32-byte CSPRNG token. Bind it to the offer, both current pins, the control binding and local trust generation. Emit `FILE_ACCEPT` with `expires_in_ms=15000`; do not create a temporary payload file until valid OPEN. |
| User rejects/decision expires | Emit `FILE_REJECT` with the contract reason, release reservations, and invalidate dialog closures. A delayed Accept action cannot revive the offer. |
| Receive acceptance | Check offer identity/hash and current control owner; dial the receiver's current SRV endpoint using only `floatcut-file/1`. Changing endpoints does not change the expected receiver ID/pin. Send only `FILE_OPEN` until matching `FILE_READY` arrives. |
| Receive `FILE_OPEN` | Validate full mTLS identity, current control owner/binding, peer generation, offer identity/hash and unexpired token. Consume the token atomically only on a complete valid OPEN. Concurrent uses cannot both receive READY. Invalid unauthenticated/cross-peer attempts cannot consume another peer's valid token. |
| Receive matching `FILE_READY` | Stream DATA in order with the exact fixed chunk size and offsets, then one END; zero-byte sources send END without DATA. No other transfers share this data stream. |
| Receive a DATA record | Check opcode, record length, offset, exact next chunk size and remaining byte budget before writing. Count only completely validated, successfully written records as completed progress. |
| Receive valid END | Verify counts and hash, retire the data channel immediately, enter the commit phase, and execute I5. Do not wait for EOF or TLS close_notify to begin commit; ignore all following bytes, including already buffered bytes, so TLS/TCP coalescing cannot change the result. |
| Control lost, timeout, disable, or revoke before publication grant | Invalidate the token and lifetime, close data, cancel unfinished workers, remove private bytes after handle release and complete the contract's failure/cancellation result. Reconnection does not resume DATA or reuse an old token. After grant, resolve actual native publication/receipt without recreating control authorization. |
| `FILE_STATUS_REQUEST` on a fresh trusted channel | Match peer pin, local trust generation, transfer ID and original offer hash; answer from active state or retained receipt. It is read-only and cannot restart transfer, create trust, or consume a new file slot. |

Use injected elapsed-time clocks for deadlines and wall-clock epoch time only
for timestamp/receipt retention. A timer's owner is the transfer lifetime; a
stale timer is discarded. Start fixed deadlines at these events and never
extend them on duplicate messages, repeated UI updates, partial frame bytes,
TLS-only records, or retries:

| Deadline | Start | Bound/action |
| --- | --- | --- |
| Receiver decision | First valid offer | 60 seconds; reject `timeout`. |
| Sender waits for decision | Offer send | 90 seconds; cancel `timeout`. |
| Receiver token/data bind | Receiver queues ACCEPT for transport | 15 seconds for a valid OPEN; receiver time is authoritative. |
| Sender waits for READY | OPEN send | Five seconds. |
| Active data idle | READY and then each complete validated DATA record | 30 seconds; partial records do not postpone expiry. |
| Accepted transfer lifetime | ACCEPT | Two hours; forbid new publication grants on expiry, without relabeling previously granted work. |
| Commit preparation | First valid END | 30 seconds through publication grant; no timer declares a granted native operation failed. |
| Sender waits for terminal result | END send | 45 seconds; then local `unconfirmed` and read-only status recovery. |

Deadline handling must become eligible at the exact deadline and execute within
one second while the process is runnable. A queued callback MUST recheck expiry
before accepting a late user decision, token, record, or worker completion. Use
a sleep-inclusive elapsed-time source, or retire pre-suspend ungranted
transfers on resume before displaying an active state. Wall-clock jumps cannot
renew a token, freeze a live transfer, or force a network timeout.

There are at most four incoming and four outgoing nonterminal file transfers
per device, and at most one in each direction per peer. Count offered,
preparing, awaiting-decision, accepted, receiving, and committing phases; release once at
terminal transition. These are independent of 32 stored pairings and clipboard
image limits. Receipt capacity is 1,024 receiver entries; reserve before
acceptance and reject `busy` when there is no slot rather than delete an
unexpired receipt. Quota checks are serialized and repeated at acceptance;
parallel UI accepts cannot exceed either bound. Optional local file reception
preference affects new offers, not a retained receipt query.
Retain at most 1,024 recent never-accepted offer IDs for ten minutes; queries and
duplicate offers do not renew entries. If the cache is full, reject new offers
with `busy` until capacity expires. Apply the contract's exact rejection
precedence; no UI component chooses a different reason or sends ACCEPT after a
destination/capacity check failed.

The sender's retained offer metadata contains transfer/offer IDs, selected peer
ID/pin, original manifest/binding and local trust generation. Persist it before
queuing OFFER so a restart can associate an uncertain delivery with its original
read-only status query. This metadata never authorizes DATA after restart and
does not keep a snapshot as an automatic retry/offline queue. A cancelled or
failed preparation deletes its private bytes and releases the reserved slot.

## I7. Persisted pairing deadlines across process restart

Persist `local_boot_generation`, `clock_id`, `start_tick_ms` and
`deadline_tick_ms` with every retained pairing context. For an uncompleted
request the deadline is its original request-start tick plus exactly 120,000
milliseconds; for completed retention it is the first completion tick plus
exactly 600,000 milliseconds. Check additions and invariants before storing.
Repeated status/completion messages do not replace start or deadline.
The initiator records request start when it queues PAIR_REQUEST; the acceptor
records it when the valid request arrives. A request's retained original local
start does not change when either side reconnects.

After process restart, restore only if the boot-generation proof and clock
representation match and `start_tick_ms <= now_tick_ms < deadline_tick_ms`.
Missing/corrupt proof, new boot, clock rollback or expiry invalidates that
context. Never reconstruct `now+120 seconds`, subtract wall-clock epoch values,
or grant the process's initialization time as a new start. Invalidating an
expired completed cache does not delete an already persisted peer/pin. A new
connection's fresh HELLO nonces never rewrite the retained original pairing
transcript.

On macOS use `mach_continuous_time`, converted with `mach_timebase_info` to
integer milliseconds using checked arithmetic, and read `kern.bootsessionuuid`
with `sysctlbyname` as the generation proof. Apple documents sleep-inclusive
monotonic ticks and exposes this read-only boot-session UUID in XNU. This is
distinct from boot-volume `kern.bootuuid`; do not substitute the latter or
derive boot identity from adjustable wall-clock boot time. If the boot-session
value cannot be read on a supported system, invalidate old contexts rather than
assume the same boot.
[Continuous elapsed clock](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time),
[boot-session sysctl definition](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/bsd/kern/kern_sysctl.c),
[sysctlbyname](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctlbyname.3.html).

On Windows use native `GetTickCount64` milliseconds. Microsoft explicitly
recommends it for elapsed time including sleep/hibernation. Do not substitute
a managed `Environment.TickCount64` without establishing its semantics for the
actual runtime version.
[Native elapsed clock](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64),
[sleep-inclusive timing guidance](https://learn.microsoft.com/en-us/windows/win32/sysinfo/interrupt-time).

For Windows boot-generation proof, create/open a dedicated versioned key under
the current user's Floatcut registry namespace with `REG_OPTION_VOLATILE`, a
protected owner-only DACL, and one CSPRNG generation value. Initialize/read it
under the app's single-instance/serialized ownership. An existing valid value
is reused across app restarts. A newly created key or missing/malformed value
gets a new generation and invalidates all old pairing contexts. Never delete
or recreate the marker on ordinary app exit. Volatile data disappears when
its hive unloads; marker loss conservatively invalidates old contexts even if
the kernel boot did not change. The dedicated key must never be created as
nonvolatile: the API ignores the volatility option for an already existing
key. Use the same registry view/path on every app architecture.
[Volatile registry creation and security descriptor](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexw).

Both native mappings are local store formats; no clock tick or boot marker
crosses the wire. Test app restart within one boot, actual reboot, sleep,
hibernation, marker loss and wall-clock jumps. A marker is never permission to
restore file tokens or DATA: file transfers remain nonresumable.

## I8. Shared transfer UI state model

Windows and macOS MUST implement the same transfer state/view model and action
semantics. Native controls, window decoration and layout may differ; phases,
peer identity, acceptance, cancellation and meaning of progress may not. One
model keyed by transfer ID drives a shared transfer-window component for both
sending and receiving. UI snapshots include engine epoch, peer generation,
transfer lifetime and increasing revision; a stale snapshot/action is ignored
on the receiving executor, including the UI thread.

| Role/phase | Required presentation and actions |
| --- | --- |
| Sender preparing | Show selected peer and file, indeterminate preparation while the private snapshot/hash is built; Cancel releases preparation. |
| Sender offered | Show waiting for the named peer's decision; Cancel invalidates the offer. |
| Receiver offered | Open the same transfer-window component with sender, suggested name and exact byte size. Offer Accept with a local destination choice, Reject and Cancel; only explicit acceptance authorizes saving. |
| Accepted/connecting | Show connection preparation to the selected peer; both sides can cancel. TLS ready alone is not receiving or saved. |
| Receiving | Show authoritative receiver byte count and percentage; both sides can cancel. Sender's submitted bytes may be secondary diagnostic/local progress, never remote success. |
| Committing | Show `Wird gespeichert und geprüft` (or its locale equivalent), disable Cancel on both clients, and retain the publication-grant ordering of I1 for stale protocol actions. Full byte count is not saved. |
| Saved | Show successful reception only after matching durable FILE_RESULT/saved; show the final name/destination on the receiver, with no automatic opening. |
| Rejected/cancelled/failed | Show stable reason and completed state. Retry is a fresh explicit Send action with a new transfer ID and new receiving decision. |
| Sender unconfirmed | Explain that final reception is unconfirmed; offer read-only status refresh after a trusted channel returns. Never automatically resend or label the remote file absent. |

The sender updates remote byte progress only from the authenticated receiver's
matching `FILE_PROGRESS`: `transfer_id`, `offer_sha256`, `received_bytes`, and
`phase` (`receiving` or `committing`). The receiver sends initial
`receiving/0` on control before it queues READY on data; the sender may receive
this initial progress before READY. Then send a coalesced monotonic byte-count update at most
once per second and at least once each second in which completed bytes advance.
The valid END transition sends `committing` immediately, bypassing intermediate
throttling. Intermediate updates cannot renew transfer/token deadlines.

`received_bytes` counts bytes in completely validated, successfully written
DATA records and never exceeds `byte_size`. Reject decreasing or impossible
counts/phase transitions according to the contract. A receiving count is a
multiple of 262,144 or exactly `byte_size`; committing requires complete size
and may follow only receiving. Identical repeated progress is harmless and
cannot renew a deadline. Calculate nonempty-file
percentage as integer `floor(100 * received_bytes / byte_size)` with checked
integer arithmetic. An empty file displays zero until valid END, then 100.
At 100% the phase still reads committing until saved. The receiver's model is
authoritative for reception; TLS send callbacks do not drive remote percentage.
Result dominates every delayed progress event, which cannot reopen a terminal
window or regress saved to receiving.

Keep blocking hash/flush/publication work on bounded workers. A stalled granted
operation remains committing/unconfirmed and available to read-only status
queries; it never stalls PING, clipboard or processing of peer revocation. Test
the filesystem's publication behavior and do not offer unsupported destinations
through a synchronous control-thread fallback.

Closing/hiding a transfer window leaves its model running and can be reopened
from the transfer list. Only the explicit Cancel action cancels a transfer;
window dismissal must not imply successful saving or discard an incoming
decision. A receiver offer left unanswered still expires at its fixed deadline.
Never select a peer by display-name equality or attach a worker/UI result to
whichever device row currently occupies the old index.

## I9. Diagnostics and conformance evidence

Log transfer state transitions, direction, elapsed-time deadlines, byte counts,
failure categories, and shortened peer/transfer IDs. Do not log file bytes,
filenames, source/destination paths, full transcript/binding hashes,
acceptance tokens, session nonces, certificate material, or comparison codes.
User-facing progress uses validated completed bytes; it must not imply remote
receipt from local write progress.

The required shared tests are in [`CONFORMANCE_V3.md`](CONFORMANCE_V3.md).
Record separately: schema/codec passes, deterministic engine passes, native
TLS/filesystem passes, and independent Windows/macOS LAN passes. A running v2
CLI, a generated fixture, or a source-reviewed API mapping is not a v3 runtime
or interop pass. A client must not claim v3 conformance or release the file
profile as complete until its applicable acceptance cases pass. Clearly
identified development/test builds may exercise the v3 wire contract to obtain
that independent evidence.
