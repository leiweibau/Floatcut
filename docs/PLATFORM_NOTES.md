# Floatcut Sync v2 – macOS platform notes

This file maps the normative protocol to the macOS implementation. It is also
the hand-off reference for an independent implementation on another platform.

## API mapping

| Requirement | macOS implementation |
|---|---|
| DNS-SD/mDNS | `NWBrowser` and `NWListener.Service`, exact service type `_floatcutsync._tcp`, `pv=2`, and sorted mandatory V2 capabilities |
| Direct TCP + TLS 1.3 | Network.framework `NWConnection`/`NWListener`, TLS minimum and maximum both set to TLS 1.3 |
| Mutual certificate authentication | `sec_protocol_options_set_local_identity`, peer authentication required, custom verify block |
| Persistent P-256 identity | Security.framework key pair in the user's login Keychain; preferences store an opaque persistent reference and the key is recoverable by its stable application tag |
| Self-signed X.509 | Minimal in-process DER builder, ECDSA-with-SHA256, ten-year validity, CA=false, digitalSignature, server/client EKU, exact device SAN |
| Pinning | SHA-256 over complete certificate DER plus exact device SAN and TLS public-key association |
| Hashes/nonces | CryptoKit SHA-256 and `SecRandomCopyBytes` |
| Discovery permission | `NSLocalNetworkUsageDescription` and `NSBonjourServices` in the app plist |
| Clipboard source guard | Main-thread `NSPasteboard.changeCount` token set plus a separate remote receive path in `AppController` |
| Persistent peer/revocation data | Atomic V2-only JSON (`peers-v2.json`, `pending-pairings-v2.json`, `revocations-v2.json`) in `~/Library/Application Support/de.meierkarsten.floatcut/Sync/`; V1 stores are not trusted by V2 |

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

## Conformance boundary

The macOS protocol, identity, and two-identity mutual-TLS tests are automated.
The TLS harness uses a real loopback `NWListener` and `NWConnection`; it is not
a mock of Security.framework or Network.framework. Real cross-platform LAN pairing,
pinning, revocation, triangle one-hop behavior, and bidirectional clipboard
transfer still require the independent other-platform build and must be run
against `docs/Protocol/CONFORMANCE_V2.md` before declaring cross-platform v2 complete.
No wire value may be changed to accommodate another platform without updating
the shared specification and fixtures (and using a new major protocol version
for an incompatible change).
