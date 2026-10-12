# V3 quality review for Floatcut 4.5.0

Date: 2026-10-11. Requested reviewer: GPT-6.1-Sol with reasoning effort ultra.
The reviewer performed an initial read-only audit and a closing review of the
implementation, native mappings, UI ownership, tests and current changes.

The closing verdict found no remaining correctness or security blocker. All
concrete findings from the initial review were corrected and checked through
targeted regression coverage.

| Finding | Correction and validation |
| --- | --- |
| Disable/re-enable could overtake authorization invalidation | Preference persistence, generation increment and cancellation now execute in the same serial transaction; production coordinator test queues both transitions around held work |
| Control EOF could leave publication authorized while clipboard work drained | The receive completion retires file authority before yielding to workers; the deterministic production receive regression holds clipboard and disk work at that boundary |
| Stale UI consent could target another engine, and progress could invalidate Cancel | Actions carry the captured engine epoch; consent requires the current offer revision, while Cancel tolerates intervening progress on the same live transfer |
| Accepted failure/cancellation receipts could be confirmed before durable persistence | Exact outcomes remain uncertain until journal persistence succeeds; injected failures verify retry, quota ownership and truthful results |
| Late outbound metadata could survive cancellation; completed metadata accumulated | Stale successful writes are compensated, outbound RAM records are removed, and controlled persist/cancel races leave no unintended resend state |
| Historical receipts bypassed expiry and accumulated across days | Durable pruning and status lookup enforce fixed retention; multi-day rollover and retained-window expiry tests pass |
| Engine replacement could race journal recovery or strand status windows | Exclusive journal ownership drains before handoff; recovered incoming receipts and outgoing status metadata update the matching retained windows across epochs |
| Local file-connection failures closed healthy clipboard control | File-local errors cancel only that transfer; subsequent control/status operations remain valid |
| Wrong control classification or establishment timing | OFFER structural validation follows trusted admission, and incoming control uses the original candidate deadline through TLS and HELLO |
| Cancelled connections could retain their candidate slots | Cancellation acknowledgments reach idempotent cleanup before the closing-state guard; the strengthened native test verifies exact connection removal and empty candidate slots within five seconds |
| Restarted receipt history could open many windows | Terminal receive history remains available in the menu without automatic presentation; explicit new send errors retain a status window |

Verification includes the production coordinator's native TLS/control tests,
the separate native file matrix and real 8-GiB transfer, file-storage fault
tests, strict contract tests, UI-state tests, existing clipboard regressions
and the Universal Release build. See
[MACOS_CONFORMANCE_V3.md](MACOS_CONFORMANCE_V3.md) for commands, measurements
and the distinction between native transport and deterministic test hooks.

This source review does not substitute for independent Windows/macOS LAN
interoperability, manual checks with both native applications, or independent
cryptographic review of the protocol construction. Those gates remain
explicitly separate from local implementation verification.
