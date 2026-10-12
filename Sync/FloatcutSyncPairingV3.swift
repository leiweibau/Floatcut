import Foundation

/// A queue-owned commit/reveal exchange. Network/UI owners explicitly call
/// `acceptRequest` and `confirmLocal`; network messages cannot perform either
/// local user decision. Original TCP binding and roles remain frozen.
final class FloatcutSyncPairingV3 {
    enum Phase: Equatable {
        case initial, awaitingChallenge, awaitingInitiatorReveal, awaitingAcceptorReveal, revealed, complete, invalidated
    }

    let requestID: String
    let localIsInitiator: Bool
    let originalControlBindingSHA256: String
    let initiatorDeviceID: String
    let initiatorCertificateSHA256: String
    let acceptorDeviceID: String
    let acceptorCertificateSHA256: String
    private(set) var deadline: FloatcutSyncBootDeadline
    private(set) var phase: Phase = .initial
    private(set) var transcript: FloatcutPairingTranscript?
    private(set) var localConfirmed = false
    private(set) var remoteConfirmed = false
    private(set) var initiatorCommitmentSHA256: String?
    private(set) var acceptorCommitmentSHA256: String?
    private var localNonce: Data?
    private let nowTickMS: () -> UInt64?
    private let bootGeneration: () -> String?

    init(requestID: String, localIsInitiator: Bool, originalControlBindingSHA256: String,
         initiatorDeviceID: String, initiatorCertificateSHA256: String,
         acceptorDeviceID: String, acceptorCertificateSHA256: String,
         deadline: FloatcutSyncBootDeadline, localNonce: Data? = nil,
         nowTickMS: @escaping () -> UInt64? = FloatcutSyncBootClock.nowTickMS,
         bootGeneration: @escaping () -> String? = FloatcutSyncBootClock.generation) throws {
        guard FloatcutSyncProtocol.isCanonicalUUID(requestID),
              FloatcutSyncProtocol.isCanonicalUUID(initiatorDeviceID),
              FloatcutSyncProtocol.isCanonicalUUID(acceptorDeviceID), initiatorDeviceID != acceptorDeviceID,
              deadline.deadlineTickMS >= deadline.startTickMS,
              deadline.deadlineTickMS - deadline.startTickMS == 120_000
        else { throw FloatcutSyncProtocolError.invalidField("pairing_context") }
        for hash in [originalControlBindingSHA256, initiatorCertificateSHA256, acceptorCertificateSHA256] {
            _ = try FloatcutSyncProtocol.dataFromHex(hash, expectedBytes: 32)
        }
        self.requestID = requestID; self.localIsInitiator = localIsInitiator
        self.originalControlBindingSHA256 = originalControlBindingSHA256
        self.initiatorDeviceID = initiatorDeviceID; self.initiatorCertificateSHA256 = initiatorCertificateSHA256
        self.acceptorDeviceID = acceptorDeviceID; self.acceptorCertificateSHA256 = acceptorCertificateSHA256
        self.deadline = deadline
        self.nowTickMS = nowTickMS; self.bootGeneration = bootGeneration
        let nonce = try localNonce ?? FloatcutSyncProtocol.secureNonce()
        guard nonce.count == 32 else { throw FloatcutSyncProtocolError.invalidField("nonce") }
        self.localNonce = nonce
        let commitment = try self.commitment(role: localIsInitiator ? "initiator" : "acceptor", nonce: nonce)
        if localIsInitiator { initiatorCommitmentSHA256 = commitment }
        else { acceptorCommitmentSHA256 = commitment }
    }

    /// Resume the already verified original exchange. The replacement control
    /// connection's HELLO binding never enters this context and no nonce is made.
    init(pending: FloatcutSyncPendingPairing) throws {
        guard pending.isValidSameBoot(), let localIsInitiator = pending.localIsInitiator,
              let deadline = pending.bootDeadline, let binding = pending.originalControlBindingSHA256,
              let initiatorID = pending.initiatorDeviceID, let initiatorPin = pending.initiatorCertificateSHA256,
              let acceptorID = pending.acceptorDeviceID, let acceptorPin = pending.acceptorCertificateSHA256,
              let initiatorCommitment = pending.initiatorCommitmentSHA256,
              let acceptorCommitment = pending.acceptorCommitmentSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        self.requestID = pending.requestID; self.localIsInitiator = localIsInitiator
        self.originalControlBindingSHA256 = binding
        self.initiatorDeviceID = initiatorID; self.initiatorCertificateSHA256 = initiatorPin
        self.acceptorDeviceID = acceptorID; self.acceptorCertificateSHA256 = acceptorPin
        self.deadline = deadline
        self.initiatorCommitmentSHA256 = initiatorCommitment
        self.acceptorCommitmentSHA256 = acceptorCommitment
        self.transcript = FloatcutPairingTranscript(inputLength: 289, sha256: pending.transcriptSHA256,
            comparisonCode: try FloatcutSyncProtocol.comparisonCode(transcriptSHA256: pending.transcriptSHA256))
        self.localConfirmed = pending.localConfirmed; self.remoteConfirmed = pending.remoteConfirmed
        self.phase = pending.complete ? .complete : .revealed
        self.localNonce = nil
        self.nowTickMS = FloatcutSyncBootClock.nowTickMS; self.bootGeneration = FloatcutSyncBootClock.generation
    }

    func requestMessage() throws -> FloatcutSyncWireMessage {
        try requireLive()
        guard localIsInitiator, phase == .initial, let initiatorCommitmentSHA256 else { throw FloatcutSyncProtocolError.invalidState }
        phase = .awaitingChallenge
        return FloatcutSyncWireMessage(type: "PAIR_REQUEST", fields: ["request_id": requestID, "initiator_commitment_sha256": initiatorCommitmentSHA256])
    }

    /// Called only after the acceptor has explicitly approved a valid request.
    func acceptRequest(initiatorCommitment: String) throws -> FloatcutSyncWireMessage {
        try requireLive()
        guard !localIsInitiator, phase == .initial, let acceptorCommitmentSHA256 else { throw FloatcutSyncProtocolError.invalidState }
        _ = try FloatcutSyncProtocol.dataFromHex(initiatorCommitment, expectedBytes: 32)
        initiatorCommitmentSHA256 = initiatorCommitment
        phase = .awaitingInitiatorReveal
        return FloatcutSyncWireMessage(type: "PAIR_CHALLENGE", fields: ["request_id": requestID, "acceptor_commitment_sha256": acceptorCommitmentSHA256])
    }

    func receiveChallenge(_ message: FloatcutSyncWireMessage) throws -> FloatcutSyncWireMessage {
        try requireLive()
        guard localIsInitiator, phase == .awaitingChallenge, message.type == "PAIR_CHALLENGE",
              try message.string("request_id") == requestID, let localNonce else { throw FloatcutSyncProtocolError.invalidState }
        let hash = try message.string("acceptor_commitment_sha256")
        _ = try FloatcutSyncProtocol.dataFromHex(hash, expectedBytes: 32)
        acceptorCommitmentSHA256 = hash
        phase = .awaitingAcceptorReveal
        return reveal(role: "initiator", nonce: localNonce)
    }

    /// Returns the acceptor's one reveal after checking the initiator's reveal.
    /// The initiator receives nil after checking the acceptor's one reveal.
    func receiveReveal(_ message: FloatcutSyncWireMessage) throws -> FloatcutSyncWireMessage? {
        try requireLive()
        let role = localIsInitiator ? "acceptor" : "initiator"
        guard phase == (localIsInitiator ? .awaitingAcceptorReveal : .awaitingInitiatorReveal),
              message.type == "PAIR_REVEAL", try message.string("request_id") == requestID,
              try message.string("role") == role, let localNonce,
              let initiatorCommitmentSHA256, let acceptorCommitmentSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        let nonce = try FloatcutSyncProtocol.decodeBase64URL(try message.string("nonce"), expectedBytes: 32)
        guard try commitment(role: role, nonce: nonce) == (localIsInitiator ? acceptorCommitmentSHA256 : initiatorCommitmentSHA256) else {
            invalidate()
            throw FloatcutSyncProtocolError.commitmentMismatch
        }
        transcript = try FloatcutSyncProtocol.pairingTranscript(
            requestID: requestID, controlBindingSHA256: originalControlBindingSHA256,
            initiatorDeviceID: initiatorDeviceID, initiatorCertificateSHA256: initiatorCertificateSHA256,
            initiatorNonce: localIsInitiator ? localNonce : nonce,
            acceptorDeviceID: acceptorDeviceID, acceptorCertificateSHA256: acceptorCertificateSHA256,
            acceptorNonce: localIsInitiator ? nonce : localNonce,
            initiatorCommitmentSHA256: initiatorCommitmentSHA256, acceptorCommitmentSHA256: acceptorCommitmentSHA256)
        phase = .revealed
        self.localNonce = nil
        return localIsInitiator ? nil : reveal(role: "acceptor", nonce: localNonce)
    }

    func confirmLocal() throws -> FloatcutSyncWireMessage {
        try requireLive()
        guard phase == .revealed || phase == .complete, let transcript else { throw FloatcutSyncProtocolError.invalidState }
        localConfirmed = true
        return FloatcutSyncWireMessage(type: "PAIR_CONFIRM", fields: ["request_id": requestID, "transcript_sha256": transcript.sha256])
    }

    func receiveConfirmation(_ message: FloatcutSyncWireMessage) throws {
        try requireLive()
        guard phase == .revealed || phase == .complete, let transcript,
              try message.string("request_id") == requestID,
              try message.string("transcript_sha256") == transcript.sha256
        else { throw FloatcutSyncProtocolError.invalidState }
        switch message.type {
        case "PAIR_CONFIRM": remoteConfirmed = true
        case "PAIR_STATUS":
            let state = try message.string("state")
            guard ["awaiting_confirmation", "confirmed", "complete"].contains(state) else { throw FloatcutSyncProtocolError.invalidState }
            if state == "confirmed" || state == "complete" { remoteConfirmed = true }
        case "PAIR_COMPLETE":
            guard localConfirmed, remoteConfirmed else { throw FloatcutSyncProtocolError.invalidState }
        default: throw FloatcutSyncProtocolError.invalidState
        }
    }

    /// Call only after the peer and both confirmations have been durably saved.
    /// A repeated completion leaves the first completion's retention unchanged.
    func markCompleted(nowTickMS: UInt64? = FloatcutSyncBootClock.nowTickMS(),
                       bootGeneration: String? = FloatcutSyncBootClock.generation()) throws {
        guard phase == .revealed || phase == .complete, localConfirmed, remoteConfirmed else { throw FloatcutSyncProtocolError.invalidState }
        if phase == .complete { return }
        guard deadline.isValid(durationMS: 120_000, nowTickMS: nowTickMS, bootGeneration: bootGeneration),
              let retention = FloatcutSyncBootDeadline.starting(durationMS: 600_000, nowTickMS: nowTickMS, bootGeneration: bootGeneration)
        else { throw FloatcutSyncProtocolError.invalidState }
        deadline = retention
        phase = .complete
    }

    func invalidate() {
        phase = .invalidated
        localNonce = nil
        transcript = nil
    }

    private func commitment(role: String, nonce: Data) throws -> String {
        try FloatcutSyncProtocol.pairingCommitment(role: role, requestID: requestID, controlBindingSHA256: originalControlBindingSHA256,
            initiatorDeviceID: initiatorDeviceID, initiatorCertificateSHA256: initiatorCertificateSHA256,
            acceptorDeviceID: acceptorDeviceID, acceptorCertificateSHA256: acceptorCertificateSHA256, nonce: nonce)
    }

    private func requireLive() throws {
        guard phase != .invalidated,
              deadline.isValid(durationMS: phase == .complete ? 600_000 : 120_000,
                               nowTickMS: nowTickMS(), bootGeneration: bootGeneration())
        else { throw FloatcutSyncProtocolError.invalidState }
    }

    private func reveal(role: String, nonce: Data) -> FloatcutSyncWireMessage {
        FloatcutSyncWireMessage(type: "PAIR_REVEAL", fields: ["request_id": requestID, "role": role, "nonce": FloatcutSyncProtocol.base64URL(nonce)])
    }
}
