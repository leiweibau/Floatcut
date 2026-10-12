# macOS V3 implementation evidence

Date: 2026-10-11. Source version: 4.5.0. The implementation targets
[Floatcut Sync V3](floatcut-sync-v3.md) and its optional `file.transfer.v1`
profile. V2 compatibility is not provided. This evidence records local native
tests separately from independent product interoperability; it does not
declare the shared V3 checklist complete.

The immutable contract snapshot is described by [V3_SNAPSHOT.json](V3_SNAPSHOT.json).
Existing files in the sibling Floatcut-SRC repository are inputs only.

Local environment: macOS 26.7.1, Xcode 26.6 (17F113), Network.framework and
Security.framework, local APFS, IPv4 loopback 127.0.0.1. Native file runs cover
both sender UUID orderings. Source base: `3c50b7711866191a9df258bbffb916969a589bda`
with the uncommitted V3/4.5.0 implementation changes in this workspace.

## Local evidence

| Area | Test and observed outcome |
| --- | --- |
| Codec, hashes and pairing | `Scripts/test-sync-protocol.sh`: strict framing/Unicode, capability supersets, commit/reveal vectors, independent confirmation flags, fixed completion retention and misplaced/unsupported offer classification pass |
| Independent contract artifacts | `Scripts/test-sync-src-codec.sh`: 108 unchanged SRC contract checks and 43 independently verified Swift-produced messages/crypto values pass; the SRC V2 runtime is not used as a V3 peer |
| Identity and persisted trust | `Scripts/test-sync-identity.sh`: separate-process Keychain reload, exact certificate profile, malformed re-signed certificates, trust generations and retained original pairing context pass |
| Native clock and lifecycle | `Scripts/test-sync-lifecycle.sh`: native boot marker, deadline equality, same-boot restoration, reboot/missing-marker/rollback invalidation and overflow checks pass |
| Native TLS | `Scripts/test-sync-tls.sh`: mutual TLS 1.3, exact control ALPN and actual authenticated certificate metadata pass |
| File parser and storage | `Scripts/test-sync-file.sh`: fragmented DATA/END boundaries, immutable snapshots, no-follow source/destination handling, APFS exclusive rename, stable inode recovery, collisions, journal rollover/expiry, cancellation and injected receipt-write failures pass |
| UI state | `Scripts/test-file-transfer-ui.sh`: stale approvals, epoch/target changes, protected terminal states, regular-file selection and sender/receiver presentation semantics pass |
| Native file transport | `Scripts/test-sync-v3-native-file.sh`: both ALPNs at the same listener port, mutually authenticated file channels, explicit consent, rejection without a file connection, 0/1/262143/262144/262145/16777216-byte files in both UUID directions, confirmed progress and lost-result status recovery pass |
| Production control integration | `Scripts/test-sync-v3-coordinator.sh`: actual production TLS/PeerConnection commit/reveal in both initiator UUID directions, held independent confirmations, bounded completed-status convergence, clipboard, consented native file transfer, rejection/cancellation, stale UI epochs, queued disable/re-enable generations and original incoming candidate deadline pass |
| Existing clipboard engine | `Scripts/test-engine.sh`, `Scripts/test-sync-work.sh`: history/search regressions, ordered work, cancellation, image staging and cleanup pass with V3 fixtures |
| Existing storage and codec performance | `Scripts/test-storage-performance.sh`, `Scripts/test-sync-performance.sh`: local benchmark runners complete without regressions/assertion failures |

Native identity/boot/network tests need normal macOS access to Keychain,
the boot-session sysctl and local sockets. Each harness uses isolated test
identities and temporary state, and removes its own artifacts.

The native file harness uses a strict-codec queue bridge for authenticated
control messages. Its file data uses real Network.framework TLS sockets; this
distinction matters when interpreting control-state coverage. The separate
production-coordinator harness covers the actual control implementation.
Its EOF ordering regression injects a test-only completion marker into the
actual decoded receive callback while clipboard and disk work are held. This
exercises the unchanged production EOF/authority-retirement path deterministically;
it does not claim that Network.framework TLS half-close produced that EOF in
the end-to-end test. These hooks are absent from application builds.
The strengthened deadline test also verifies removal of the exact cancelled
connection and release of all corresponding candidate slots within five seconds.

The Universal Release build succeeds for `arm64` and `x86_64`, with both
`CFBundleShortVersionString` and `CFBundleVersion` equal to `4.5.0`. The local
validation build disables signing; it is not a notarized distribution.

## Real maximum-size transfer

The native maximum case transmitted exactly 8,589,934,592 bytes between two
independent native identities, using a real private source snapshot and receiver
staging file on APFS. The receiver persisted `saved`, and an independent
streamed destination hash matched:

```text
4220c073e8af4dedf5d3217fb3e883ff756de04a740204a928e2db9b9aaee942
```

Measured transfer time including source snapshot preparation: 147.93 seconds.
Total source generation, transfer and destination verification: 201.63 seconds.
CPU time: 165.51 seconds. Peak process RSS: 66.10 MiB. These measurements describe
this local harness run, not a network throughput guarantee. Source generation
and destination verification streamed bounded buffers; neither loaded 8 GiB
into RAM. Its temporary source, snapshot and received files were removed.

Set `FLOATCUT_V3_MAXIMUM_FILE_TEST=1` to include this optional costly case in
the native runner. The usual small-file matrix remains the default.

## Independent gates

The following evidence remains separate and is not claimed by local loopback
tests:

- Windows-to-macOS and macOS-to-Windows LAN runs with independent V3 products,
  both UUID orderings, IPv4/IPv6 scope and multiple adapters.
- Real device sleep/wake, network switching, local-network permission and
  firewall behavior across that matrix.
- Independent cryptographic review of the complete pairing construction.
- Manual presentation checks with both native applications, beyond local
  state tests and compilation.

The pinned SRC snapshot recorded a V2 Python reference runtime. The sibling
SRC has since updated its status to a V3 runtime in a separate work session.
That external update is not independent interoperability evidence for this
macOS client; the copied contract remains pinned and unchanged. Its
schemas/fixtures and contract tests are shared inputs, not substitutes for
a recorded independent runtime run. The shared [conformance checklist](CONFORMANCE_V3.md)
remains the release acceptance contract.
