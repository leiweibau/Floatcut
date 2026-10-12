# Floatcut Sync v3 – macOS platform notes

This file maps the normative protocol to the macOS implementation. It is also
the hand-off reference for an independent implementation on another platform.

## API mapping

| Requirement | macOS implementation |
|---|---|
| DNS-SD/mDNS | `NWBrowser` and `NWListener.Service`, exact service type `_floatcutsync._tcp`, `pv=3`, the required clipboard capabilities and `file.transfer.v1`; valid capability supersets are accepted |
| Direct TCP + TLS 1.3 | Network.framework `NWConnection`/`NWListener`, TLS minimum and maximum both set to TLS 1.3 |
| Mutual certificate authentication | `sec_protocol_options_set_local_identity`, peer authentication required, custom verify block |
| Persistent P-256 identity | Security.framework key pair in the user's login Keychain; preferences store an opaque persistent reference and the key is recoverable by its stable application tag |
| Self-signed X.509 | Minimal in-process DER builder, ECDSA-with-SHA256, ten-year validity, CA=false, digitalSignature, server/client EKU, exact device SAN |
| Pinning | SHA-256 over complete certificate DER plus exact device SAN and TLS public-key association |
| Hashes/nonces | CryptoKit SHA-256 and `SecRandomCopyBytes` |
| Discovery permission | `NSLocalNetworkUsageDescription` and `NSBonjourServices` in the app plist |
| Clipboard source guard | Main-thread `NSPasteboard.changeCount` token set plus a separate remote receive path in `AppController` |
| Persistent peer/revocation data | V3-only JSON (`peers-v3.json`, `pending-pairings-v3.json`, `revocations-v3.json`, `trust-generations-v3.json`) in `~/Library/Application Support/de.meierkarsten.floatcut/Sync/`; V1/V2 stores are archived and never authorize V3 |

## Keychain compatibility decision

Floatcut is intentionally unsandboxed and may be only locally/ad-hoc signed.
The Data Protection Keychain returned `errSecNotAvailable` in that deployment
shape and therefore cannot be the sole sync-identity storage backend. Creating an
ephemeral key with `SecKeyCreateRandomKey` and adding it afterwards did not
produce a key/certificate association resolvable as a `SecIdentity`.

The implementation consequently uses the native login Keychain and creates the
permanent P-256 pair directly with `SecKeyGeneratePair`. This API is deprecated
but remains available on Floatcut's macOS 13.5 deployment target and is the
safest tested native mechanism that produces a usable, persistent
`SecIdentity` for mutual TLS in an unsandboxed/local-signing build. The private
key is never written to preferences or an application file and is never sent
over the network. Preferences contain only opaque persistent Keychain
references and the public certificate DER. If macOS invalidates an opaque
reference, Floatcut locates the same private key by its stable application tag
and refreshes the reference without changing the identity. A reloaded legacy
login-Keychain key may return `nil` from `SecKeyCopyPublicKey`; association with
the certificate is therefore proven by signing a fixed non-secret challenge
and verifying it with the certificate public key. Isolated regression tests
cover separate-process reload, stale-reference recovery, validation, and reset.

Future signed/sandboxed distributions may add a Data Protection Keychain
backend after a migration test, but must preserve the existing identity and
pins. Silently regenerating an identity is prohibited.

## Clipboard and one-hop behavior

The existing polling remains active and probes pasteboard types before the
`changeCount` fast path, preserving Universal Clipboard/Handoff materialization.
Only a local text item accepted by the existing skip/store/redundancy path calls
`sendAcceptedLocalText`. A remote message is validated first, enters a distinct
delegate method, is stored with the peer display name, and is written to the
system pasteboard with a bounded self-write token. That method contains no
outbound call. This structural separation enforces one hop even when ordinary
duplicate removal is disabled.

Pausing Floatcut's capture pauses sending and applying remote clipboard data;
discovery and device management remain available. Images, favorites, existing
history, skipped/password-like values, and offline clips are never queued or
backfilled. Locally accepted PNG/JPEG images are transferred only to peers for
which the user enabled the default-off gear-menu setting. That setting never
blocks reception. TIFF clipboard data is normalized to PNG off the main thread.
Incoming images are assembled in private partial files, verified before import,
marked as received from sync, and written with the same pasteboard block token
used by remote text, so they cannot be forwarded.

## V3 control and files

Only protocol V3 is active. V2 peers must update and pair again; there is no
compatibility mode or silent downgrade. Pairing uses the normative commit/reveal
exchange and keeps local confirmation independent from remote status. Pending
and completed recovery records retain fixed `mach_continuous_time` millisecond
bounds and `kern.bootsessionuuid`; a changed or missing boot marker invalidates
recovery without deleting established peer trust. All 32 persisted peers count,
including offline and disabled records.

One serial engine queue owns authorization, live generations, control slots,
file quotas, token claims and publication grants. Disk work runs on a bounded
worker pool. Both connection classes use one SRV port with mutual TLS 1.3:
`floatcut-sync/3` carries control and clipboard; `floatcut-file/1` carries exactly
one accepted file. Negotiated ALPN and the actual peer certificate are checked
before application parsing; session tickets/resumption and False Start are
explicitly disabled.

The client button beside Search and Favorites captures one authenticated device
ID, pin and engine/connection generation before the file chooser. A receiver
must explicitly accept and choose a destination directory. Both directions use
`FloatcutTransferWindowController` and the same state model. Remote percentage
counts only complete DATA records successfully written by the receiver; 100%
never substitutes for a durable `FILE_RESULT/saved`. Hiding the window leaves
the transfer running and the client menu can reopen it.

Regular files from zero through 8 GiB are immutable private source snapshots,
streamed in 262,144-byte records with bounded buffers. Symlinks, directories,
packages and nonregular sources are rejected. File bytes never enter clipboard
history, offline queues or fan-out.

Destinations initially support local APFS. Private same-filesystem staging uses
retained no-follow directory/file descriptors, mode 0700/0600 and removed
inherited ACLs. Publication uses `renameatx_np(..., RENAME_EXCL)` after hash,
flush and durable prepared-journal checks. The serial publication grant is the
cancellation boundary. Saved receipts require actual publication plus durable
receipt persistence; collisions never overwrite existing files.

The file journal is protected by exclusive ownership across engine epochs.
Startup checks stable `st_dev`/`st_ino`, exact size/hash and publication evidence
before repairing saved receipts. A receipt remains historical if the user later
moves/deletes the file. Tokens and file channels never resume across restart;
outbound metadata permits only read-only status queries. Terminal receiver
receipts expire after 24 hours; operational timeouts use continuous elapsed time.

## Conformance boundary

The macOS protocol, identity, and two-identity mutual-TLS tests are automated.
The TLS harness uses a real loopback `NWListener` and `NWConnection`; it is not
a mock of Security.framework or Network.framework. Real cross-platform LAN pairing,
pinning, revocation, triangle one-hop behavior, and bidirectional clipboard
transfer still require the independent other-platform build and must be run
against `docs/Protocol/CONFORMANCE_V3.md` before declaring cross-platform V3 complete.
No wire value may be changed to accommodate another platform without updating
the shared specification and fixtures (and using a new major protocol version
for an incompatible change).

Current V3 evidence and outstanding independent gates are recorded in
[MACOS_CONFORMANCE_V3.md](Protocol/MACOS_CONFORMANCE_V3.md). Native loopback
tests are distinct from Windows/macOS LAN interoperability and independent
review of the pairing construction.
