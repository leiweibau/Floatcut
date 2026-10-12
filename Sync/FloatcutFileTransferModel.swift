import Foundation

/// Captured authority. Reordering a menu or replacing a control channel cannot
/// retarget a user action. Every asynchronous result is checked against this.
struct FloatcutFilePeerContext: Equatable {
    let deviceID: String
    let name: String
    let certificateSHA256: String
    let trustGeneration: UInt64
    let peerGeneration: UInt64
    let controlConnectionID: UUID
    let controlBindingSHA256: String
    let engineEpoch: UInt64
    let mutualFileCapability: Bool
    static func == (a: Self, b: Self) -> Bool {
        // Display names carry no authority and can change without retargeting.
        a.deviceID == b.deviceID && a.certificateSHA256 == b.certificateSHA256
            && a.trustGeneration == b.trustGeneration && a.peerGeneration == b.peerGeneration
            && a.controlConnectionID == b.controlConnectionID && a.controlBindingSHA256 == b.controlBindingSHA256
            && a.engineEpoch == b.engineEpoch && a.mutualFileCapability == b.mutualFileCapability
    }
}

struct FloatcutFileClientTarget: Identifiable {
    let id: String
    let name: String
    let platform: String
    let isAvailable: Bool
    let unavailableReason: String?
    let context: FloatcutFilePeerContext?
}

enum FloatcutFileTransferDirection: String, Codable { case outgoing, incoming }
enum FloatcutFileTransferPhase: String, Codable {
    case preparing, offered, connecting, receiving, committing
    case saved, rejected, cancelled, failed, unconfirmed
    var isTerminal: Bool {
        switch self { case .saved, .rejected, .cancelled, .failed, .unconfirmed: return true; default: return false }
    }
}

struct FloatcutFileTransferSnapshot: Identifiable, Equatable {
    let id: String
    let direction: FloatcutFileTransferDirection
    let phase: FloatcutFileTransferPhase
    let peerDeviceID: String
    let peerName: String
    let fileName: String
    let byteSize: Int64
    let receivedBytes: Int64
    let revision: UInt64
    let engineEpoch: UInt64
    let localDestination: URL?
    let reason: String?
    let hasVerifiedEnd: Bool
    init(id: String, direction: FloatcutFileTransferDirection, phase: FloatcutFileTransferPhase,
         peerDeviceID: String, peerName: String, fileName: String, byteSize: Int64,
         receivedBytes: Int64, revision: UInt64, engineEpoch: UInt64, localDestination: URL?,
         reason: String?, hasVerifiedEnd: Bool? = nil) {
        self.id = id; self.direction = direction; self.phase = phase; self.peerDeviceID = peerDeviceID
        self.peerName = peerName; self.fileName = fileName; self.byteSize = byteSize; self.receivedBytes = receivedBytes
        self.revision = revision; self.engineEpoch = engineEpoch; self.localDestination = localDestination; self.reason = reason
        self.hasVerifiedEnd = hasVerifiedEnd ?? (phase == .committing || phase == .saved)
    }
    var percentage: Int {
        if byteSize == 0 { return phase == .saved || (phase == .committing && hasVerifiedEnd) ? 100 : 0 }
        guard byteSize > 0 else { return 0 }
        let bytes = UInt64(min(byteSize, max(0, receivedBytes)))
        return Int(UInt64(byteSize).dividingFullWidth(bytes.multipliedFullWidth(by: 100)).quotient)
    }
    var canCancel: Bool { !phase.isTerminal && phase != .committing }
    var canAccept: Bool { direction == .incoming && phase == .offered }
    var canRefreshStatus: Bool { direction == .outgoing && phase == .unconfirmed }
    var finalFileName: String { localDestination?.lastPathComponent ?? "\(id)-\(fileName)" }
}

struct FloatcutFileManifest: Codable, Equatable {
    let transferID: String
    let senderDeviceID: String
    let receiverDeviceID: String
    let fileName: String
    let byteSize: Int64
    let contentSHA256: String
    let offerSHA256: String
}

enum FloatcutFileFailure: Error {
    case reason(String)
    var wireReason: String { if case .reason(let value) = self { return value }; return "io_error" }
}
