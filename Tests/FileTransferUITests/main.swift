import AppKit
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}

let transferID = "12345678-1234-4234-8234-123456789012"
func snapshot(_ phase: FloatcutFileTransferPhase, revision: UInt64 = 1, epoch: UInt64 = 1,
              direction: FloatcutFileTransferDirection = .incoming,
              peer: String = "12345678-1234-4234-8234-123456789013") -> FloatcutFileTransferSnapshot {
    FloatcutFileTransferSnapshot(id: transferID, direction: direction, phase: phase,
        peerDeviceID: peer, peerName: "Client", fileName: "example.txt", byteSize: 100,
        receivedBytes: phase == .saved ? 100 : 0, revision: revision, engineEpoch: epoch,
        localDestination: nil, reason: nil)
}

// Returning from the folder dialog never authorizes an offer that expired,
// disconnected, changed ownership or was rejected while the dialog was open.
let selectedOffer = snapshot(.offered)
expect(FloatcutFileTransferPresentation.canApprove(selectedOffer, selectedOffer: selectedOffer), "current offer was not approvable")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.failed, revision: 2), selectedOffer: selectedOffer), "expired offer approved")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.rejected, revision: 2), selectedOffer: selectedOffer), "rejected offer approved")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.offered, revision: 2), selectedOffer: selectedOffer), "stale dialog revision approved")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.offered, epoch: 2), selectedOffer: selectedOffer), "old engine dialog approved")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.offered, peer: "different-peer"), selectedOffer: selectedOffer), "dialog retargeted to another client")
expect(!FloatcutFileTransferPresentation.canApprove(snapshot(.offered, direction: .outgoing), selectedOffer: selectedOffer), "outgoing offer approved as incoming")

// Delayed snapshots cannot undo durable success or restart data transfer after
// a lost result. A subsequent status response may resolve uncertainty.
let saved = snapshot(.saved, revision: 5)
expect(!FloatcutFileTransferPresentation.accepts(snapshot(.receiving, revision: 6), after: saved), "late progress replaced saved state")
expect(!FloatcutFileTransferPresentation.accepts(snapshot(.failed, revision: 6), after: saved), "saved state became failed")
expect(!FloatcutFileTransferPresentation.accepts(snapshot(.saved, revision: 4), after: saved), "older result replaced newer result")
expect(!FloatcutFileTransferPresentation.accepts(snapshot(.saved, revision: 7, epoch: 0), after: saved), "old engine snapshot accepted")
let unconfirmed = snapshot(.unconfirmed, revision: 5, direction: .outgoing)
expect(FloatcutFileTransferPresentation.accepts(snapshot(.saved, revision: 6, direction: .outgoing), after: unconfirmed), "status confirmation did not resolve uncertainty")
expect(!FloatcutFileTransferPresentation.accepts(snapshot(.receiving, revision: 6, direction: .outgoing), after: unconfirmed), "unconfirmed transfer resumed data")
expect(FloatcutFileTransferPresentation.accepts(snapshot(.saved, epoch: 2, direction: .outgoing), after: unconfirmed), "new engine could not resolve retained uncertainty")

// Restarted receipt history stays reachable in the menu without opening a
// window for every historical reception. Explicit local send failures are shown.
for phase in [FloatcutFileTransferPhase.saved, .failed, .cancelled, .rejected] {
    expect(!FloatcutFileTransferPresentation.shouldPresentNew(snapshot(phase)), "receipt history opened a window on restart")
}
expect(FloatcutFileTransferPresentation.shouldPresentNew(snapshot(.offered)), "incoming offer did not request approval")
expect(FloatcutFileTransferPresentation.shouldPresentNew(snapshot(.preparing, direction: .outgoing)), "new Send did not open status")
expect(FloatcutFileTransferPresentation.shouldPresentNew(snapshot(.failed, direction: .outgoing)), "immediate Send failure stayed hidden")
expect(!FloatcutFileTransferPresentation.shouldPresentNew(unconfirmed), "restored uncertain history opened automatically")

// Panel-level validation rejects directories and symlinks before a send action.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloatcutV3UITests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("regular.txt")
try Data("test".utf8).write(to: source)
let symlink = directory.appendingPathComponent("link.txt")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
let validator = FloatcutRegularFilePanelDelegate()
try validator.panel(NSObject(), validate: source)
for invalidURL in [directory, symlink] {
    do {
        try validator.panel(NSObject(), validate: invalidURL)
        fatalError("non-regular source accepted")
    } catch {}
}

print("File transfer presentation tests passed.")
