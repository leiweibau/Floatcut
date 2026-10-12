import AppKit
import Combine

/// The presentation contract can be exercised without opening the application's
/// network listener, Keychain identity or clipboard history.
@objcMembers public final class FloatcutSyncCoordinator: NSObject, ObservableObject {
    public static let shared = FloatcutSyncCoordinator()
    @Published var fileClientTargets: [FloatcutFileClientTarget] = []
    @Published var fileTransfers: [FloatcutFileTransferSnapshot] = []
    @nonobjc func sendFile(url: URL, peer: FloatcutFileClientTarget) {}
    func acceptFileTransfer(id: String, directory: URL, revision: UInt64, engineEpoch: UInt64) {}
    func rejectFileTransfer(id: String, revision: UInt64, engineEpoch: UInt64) {}
    func cancelFileTransfer(id: String, revision: UInt64, engineEpoch: UInt64) {}
    func refreshFileTransferStatus(id: String) {}
}
