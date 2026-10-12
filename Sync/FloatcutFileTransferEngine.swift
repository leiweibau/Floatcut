import Foundation
import Network

/// File decisions share the control engine's serial queue. The only blocking
/// operations are submitted to a bounded pool and return with captured authority.
final class FloatcutFileTransferEngine {
    private final class Transfer {
        let id: String
        let direction: FloatcutFileTransferDirection
        let peer: FloatcutFilePeerContext
        let lifetime = UUID()
        var phase: FloatcutFileTransferPhase
        var fileName: String
        var manifest: FloatcutFileManifest?
        var revision: UInt64 = 0
        var receivedBytes: Int64 = 0
        var progressPhase = "receiving"
        var reason: String?
        var destination: URL?
        var snapshot: FloatcutFileStorage.Snapshot?
        var storage: FloatcutFileStorage?
        var journalRecord: FloatcutFileTransferJournal.Record?
        var channel: FloatcutFileDataConnection?
        var parser: FloatcutFileBinaryParser?
        var token: Data?
        var tokenClaimed = false
        var accepted = false
        var accepting = false
        var publicationGranted = false
        var workInvalidated = false
        var quotaReserved = true
        var offerDeadline: TimeInterval?
        var tokenDeadline: TimeInterval?
        var readyDeadline: TimeInterval?
        var idleDeadline: TimeInterval?
        var totalDeadline: TimeInterval?
        var commitDeadline: TimeInterval?
        var resultDeadline: TimeInterval?
        var lastProgressAt: TimeInterval = 0
        var lastProgressBytes: Int64 = 0
        var sentOffset: Int64 = 0
        var endSent = false
        var offerSent = false
        var terminalResult: FloatcutSyncWireMessage?
        var pendingResultRecord: FloatcutFileTransferJournal.Record?
        var pendingResult: FloatcutSyncWireMessage?
        var pendingResultPhase: String?
        var persistenceInFlight = false
        init(id: String, direction: FloatcutFileTransferDirection, peer: FloatcutFilePeerContext, phase: FloatcutFileTransferPhase, fileName: String) {
            self.id = id; self.direction = direction; self.peer = peer; self.phase = phase; self.fileName = fileName
        }
    }
    private struct RecentOffer { let expires: TimeInterval; let peer: FloatcutFilePeerContext; var rejection: FloatcutSyncWireMessage? }
    private struct Candidate { let channel: FloatcutFileDataConnection; let deadline: TimeInterval; let peer: FloatcutFilePeerContext }
    private let queue: DispatchQueue
    private let workers: OperationQueue
    private let localDeviceID: String
    private let localCertificateSHA256: String
    private let epoch: UInt64
    private let clock: FloatcutSyncElapsedClock
    private let wallClock: () -> Int64
    private let journal: FloatcutFileTransferJournal
    private let beforeJournalWrite: ((FloatcutFileTransferJournal.Record) throws -> Void)?
    private let lookupPeer: (String) -> FloatcutFilePeerContext?
    private let sendControl: (FloatcutFilePeerContext, FloatcutSyncWireMessage) -> Void
    private let connectFile: (FloatcutFilePeerContext) throws -> NWConnection
    private let onSnapshots: ([FloatcutFileTransferSnapshot]) -> Void
    var onCandidateFinished: (() -> Void)?
    private var timer: DispatchSourceTimer?
    private var transfers: [String: Transfer] = [:]
    private var recentOffers: [String: RecentOffer] = [:]
    private var records: [String: FloatcutFileTransferJournal.Record] = [:]
    private var receiptReservations: Set<String> = []
    private var candidates: [UUID: Candidate] = [:]
    private var revision: UInt64 = 0
    private var ready = false
    private var stopped = false
    private var recoveryFailed = false
    private var pendingDiskWork = 0
    private var relinquishing = false
    private var ownershipRelinquished = false
    var receivingEnabled = true
    var preOpenCandidateCount: Int { candidates.count }
    var isReady: Bool { ready && !stopped && !recoveryFailed }
    var canRetire: Bool { stopped && ownershipRelinquished }

    init(queue: DispatchQueue, localDeviceID: String, localCertificateSHA256: String, epoch: UInt64,
         metadataDirectory: URL, clock: FloatcutSyncElapsedClock = FloatcutSyncContinuousClock(),
         lookupPeer: @escaping (String) -> FloatcutFilePeerContext?,
         sendControl: @escaping (FloatcutFilePeerContext, FloatcutSyncWireMessage) -> Void,
         connectFile: @escaping (FloatcutFilePeerContext) throws -> NWConnection,
         onSnapshots: @escaping ([FloatcutFileTransferSnapshot]) -> Void,
         diskWorkers: OperationQueue? = nil,
         wallClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         beforeJournalWrite: ((FloatcutFileTransferJournal.Record) throws -> Void)? = nil) {
        self.queue = queue; self.localDeviceID = localDeviceID; self.localCertificateSHA256 = localCertificateSHA256
        self.epoch = epoch; self.clock = clock; self.wallClock = wallClock; self.lookupPeer = lookupPeer; self.sendControl = sendControl
        self.connectFile = connectFile; self.onSnapshots = onSnapshots
        self.beforeJournalWrite = beforeJournalWrite
        journal = FloatcutFileTransferJournal(directory: metadataDirectory, wallClock: wallClock)
        workers = diskWorkers ?? OperationQueue(); workers.name = "de.meierkarsten.floatcut.file-io"; workers.maxConcurrentOperationCount = 4
        workers.qualityOfService = .utility
        let now = wallClock()
        submitIO { [self] in
            let result = Result { try journal.loadAndReconcile(nowMilliseconds: now) }
            queue.async { [self] in
                guard !stopped else { return }
                switch result {
                case .success(let loaded):
                    for record in loaded {
                        records[record.manifest.transferID] = record
                        if record.direction == .incoming { receiptReservations.insert(record.manifest.transferID) }
                        if record.direction == .outgoing || ["saved", "failed", "cancelled"].contains(record.state) {
                            // Recovery is metadata only; no snapshot, offer or data channel resumes.
                            let context = FloatcutFilePeerContext(deviceID: record.peerID, name: record.peerName,
                                certificateSHA256: record.peerPin, trustGeneration: record.trustGeneration,
                                peerGeneration: 0, controlConnectionID: UUID(), controlBindingSHA256: "", engineEpoch: epoch, mutualFileCapability: true)
                            let recoveredPhase: FloatcutFileTransferPhase = record.direction == .outgoing ? .unconfirmed
                                : (record.state == "saved" ? .saved : (record.state == "cancelled" ? .cancelled : .failed))
                            let transfer = Transfer(id: record.manifest.transferID, direction: record.direction, peer: context,
                                                    phase: recoveredPhase, fileName: record.manifest.fileName)
                            transfer.manifest = record.manifest; transfer.quotaReserved = false; transfer.accepted = true
                            transfer.reason = record.reason
                            if record.direction == .incoming {
                                transfer.terminalResult = resultMessage(record)
                                transfer.receivedBytes = record.state == "saved" ? record.manifest.byteSize : 0
                                if let directory = record.destinationDirectory, let leaf = record.finalLeaf {
                                    transfer.destination = URL(fileURLWithPath: directory).appendingPathComponent(leaf)
                                }
                            }
                            transfers[transfer.id] = transfer; touch(transfer)
                        }
                    }
                    ready = true
                case .failure: recoveryFailed = true
                }
                publish()
            }
        }
        queue.async { [self] in
            guard !stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.reconcile() }
            self.timer = timer; timer.resume()
        }
    }

    /// Actions enqueue onto the same queue as file control. A UI revision is an
    /// authority token and never grants access merely by retaining a window.
    @discardableResult func sendFile(url: URL, peer: FloatcutFilePeerContext) -> String {
        let id = FloatcutSyncProtocol.uuidV4()
        queue.async { [self] in
            reconcile()
            let transfer = Transfer(id: id, direction: .outgoing, peer: peer, phase: .preparing,
                                    fileName: FloatcutSyncProtocol.portableFileName(url.lastPathComponent))
            transfers[id] = transfer
            guard ready, !stopped, isCurrent(peer), peer.mutualFileCapability,
                  records.values.filter({ $0.direction == .outgoing }).count < 1024,
                  hasSlot(direction: .outgoing, peerID: peer.deviceID, excluding: id) else {
                transfer.quotaReserved = false; transfer.phase = .failed; transfer.reason = "unavailable"; touch(transfer); publish(); return
            }
            touch(transfer); publish()
            submitIO { [self] in
                let result = Result { try FloatcutFileStorage.snapshot(source: url, in: journal.directory) }
                queue.async { [self] in
                    guard isActive(transfer), isCurrent(peer) else {
                        if case .success(let snapshot) = result { cleanup(snapshot) }; return
                    }
                    switch result {
                    case .failure(let error): localFailure(transfer, reason: Self.reason(error))
                    case .success(let snapshot):
                        transfer.snapshot = snapshot
                        do {
                            let digest = try FloatcutSyncProtocol.fileOfferDigest(transferID: id, controlBindingSHA256: peer.controlBindingSHA256,
                                senderDeviceID: localDeviceID, receiverDeviceID: peer.deviceID, byteSize: snapshot.byteSize,
                                contentSHA256: snapshot.contentSHA256, fileName: transfer.fileName)
                            transfer.manifest = FloatcutFileManifest(transferID: id, senderDeviceID: localDeviceID, receiverDeviceID: peer.deviceID,
                                fileName: transfer.fileName, byteSize: snapshot.byteSize, contentSHA256: snapshot.contentSHA256, offerSHA256: digest)
                            let record = makeRecord(transfer, state: "outbound")
                            transfer.journalRecord = record
                            submitIO { [self] in
                                let persist = Result { try writeJournal(record) }
                                queue.async { [self] in
                                    guard isActive(transfer), isCurrent(peer) else {
                                        retireSnapshot(transfer); records.removeValue(forKey: id)
                                        submitIO { [journal] in try? journal.removeOutbound(id) }
                                        return
                                    }
                                    switch persist {
                                    case .failure: localFailure(transfer, reason: "io_error")
                                    case .success:
                                        records[id] = record; transfer.phase = .offered; transfer.offerDeadline = clock.now() + 90
                                        let manifest = transfer.manifest!
                                        transfer.offerSent = true
                                        send(transfer, "FILE_OFFER", ["target_device_id": peer.deviceID, "file_name": manifest.fileName,
                                            "byte_size": manifest.byteSize, "content_sha256": manifest.contentSHA256, "offer_sha256": manifest.offerSHA256])
                                        touch(transfer); publish()
                                    }
                                }
                            }
                        } catch { localFailure(transfer, reason: "io_error") }
                    }
                }
            }
        }
        return id
    }

    func accept(id: String, directory: URL, revision expectedRevision: UInt64) {
        queue.async { [self] in
            reconcile()
            guard let transfer = transfers[id], transfer.direction == .incoming, transfer.phase == .offered,
                  transfer.revision == expectedRevision, !transfer.accepting, isActive(transfer), isCurrent(transfer.peer),
                  let manifest = transfer.manifest else { return }
            transfer.accepting = true
            submitIO { [self] in
                let destination = Result { try FloatcutFileStorage(directory: directory, finalLeaf: "\(id)-\(manifest.fileName)", requiredBytes: manifest.byteSize) }
                queue.async { [self] in
                    guard isActive(transfer), transfer.phase == .offered, isCurrent(transfer.peer), !hasExpired(transfer) else {
                        receiptReservations.remove(id)
                        if case .success(let storage) = destination { cleanup(storage) }; return
                    }
                    switch destination {
                    case .failure(let error):
                        receiptReservations.remove(id); transfer.accepting = false
                        let reason = Self.reason(error)
                        rejectOffer(transfer, reason: ["destination_exists", "unsupported_destination", "no_space"].contains(reason) ? reason : "unsupported_destination")
                    case .success(let storage):
                        // Destination conflicts/support/space precede receipt
                        // exhaustion. Parallel disk completions reserve here.
                        guard receiptReservations.count < 1024 else {
                            cleanup(storage); transfer.accepting = false; rejectOffer(transfer, reason: "busy"); return
                        }
                        receiptReservations.insert(id)
                        transfer.storage = storage; transfer.destination = directory.appendingPathComponent(storage.finalLeaf)
                        var record = makeRecord(transfer, state: "accepted")
                        record.destinationDirectory = directory.path; record.destinationIdentity = storage.directoryIdentity
                        record.stagingLeaf = storage.stagingLeaf; record.finalLeaf = storage.finalLeaf
                        transfer.journalRecord = record
                        submitIO { [self] in
                            let persisted = Result { try writeJournal(record) }
                            queue.async { [self] in
                                guard isActive(transfer), transfer.phase == .offered, isCurrent(transfer.peer), !hasExpired(transfer) else {
                                    // A durable accepted entry must end with control_lost even if
                                    // cancellation raced the write. No token is ever issued here.
                                    if case .success = persisted { persistAbandoned(transfer, record: record) }
                                    else { receiptReservations.remove(id) }
                                    cleanup(storage); return
                                }
                                switch persisted {
                                case .failure: receiptReservations.remove(id); rejectOffer(transfer, reason: "unsupported_destination")
                                case .success:
                                    do {
                                        transfer.token = try FloatcutSyncProtocol.secureNonce()
                                        transfer.accepted = true; transfer.accepting = false; transfer.phase = .connecting
                                        transfer.tokenDeadline = clock.now() + 15; transfer.totalDeadline = clock.now() + 7200
                                        transfer.offerDeadline = nil; records[id] = record
                                        recentOffers.removeValue(forKey: id)
                                        send(transfer, "FILE_ACCEPT", ["offer_sha256": manifest.offerSHA256,
                                            "accept_token": FloatcutSyncProtocol.base64URL(transfer.token!), "expires_in_ms": 15000])
                                        touch(transfer); publish()
                                    } catch { finishReceiver(transfer, status: "failed", reason: "io_error") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func reject(id: String, revision expected: UInt64) {
        queue.async { [self] in
            reconcile()
            guard let transfer = transfers[id], transfer.revision == expected, transfer.direction == .incoming, transfer.phase == .offered else { return }
            rejectOffer(transfer, reason: "user_rejected")
        }
    }
    func cancel(id: String, revision expected: UInt64) {
        queue.async { [self] in
            reconcile()
            guard let transfer = transfers[id], expected <= transfer.revision, !transfer.phase.isTerminal,
                  !transfer.publicationGranted, transfer.pendingResult == nil else { return }
            cancelTransfer(transfer, reason: "user_cancelled", remote: false)
        }
    }
    func refreshStatus(id: String) {
        queue.async { [self] in
            reconcile()
            guard ready, !stopped, let transfer = transfers[id], transfer.direction == .outgoing, transfer.phase == .unconfirmed,
                  let manifest = transfer.manifest, let peer = lookupPeer(transfer.peer.deviceID), sameTrust(peer, transfer.peer) else { return }
            sendControl(peer, FloatcutSyncWireMessage(type: "FILE_STATUS_REQUEST", fields: ["transfer_id": id, "offer_sha256": manifest.offerSHA256]))
        }
    }

    /// Called only by the control owner on this engine's authority queue.
    func handleControl(_ message: FloatcutSyncWireMessage, peer: FloatcutFilePeerContext) throws {
        reconcile()
        guard !stopped, isCurrent(peer) else { throw FloatcutSyncProtocolError.invalidState }
        if message.type == "FILE_OFFER" { try receiveOffer(message, peer: peer); return }
        let id = try message.string("transfer_id")
        if message.type == "FILE_STATUS_REQUEST" { try answerStatus(id: id, hash: message.string("offer_sha256"), peer: peer); return }
        if message.type == "FILE_CANCEL", let recent = recentOffers[id], sameTrust(recent.peer, peer), let rejection = recent.rejection {
            sendControl(peer, rejection); return
        }
        guard let transfer = transfers[id], transfer.peer.deviceID == peer.deviceID, sameTrust(peer, transfer.peer) else {
            // A retained receiver result also answers late cancellation idempotently.
            if message.type == "FILE_CANCEL", let record = records[id], record.direction == .incoming,
               matches(record, peer: peer), ["saved", "failed", "cancelled"].contains(record.state) {
                sendControl(peer, resultMessage(record)); return
            }
            throw FloatcutSyncProtocolError.invalidState
        }
        let isRecovery = transfer.direction == .outgoing && transfer.phase == .unconfirmed
        guard isRecovery || peer == transfer.peer else { throw FloatcutSyncProtocolError.invalidState }
        switch message.type {
        case "FILE_ACCEPT":
            guard transfer.direction == .outgoing, transfer.phase == .offered, !hasExpired(transfer),
                  try message.string("offer_sha256") == transfer.manifest?.offerSHA256 else { throw FloatcutSyncProtocolError.invalidState }
            transfer.accepted = true; transfer.phase = .connecting; transfer.offerDeadline = nil
            transfer.totalDeadline = clock.now() + 7200
            let token = try FloatcutSyncProtocol.decodeBase64URL(message.string("accept_token"), expectedBytes: 32)
            do { try startSenderChannel(transfer, token: token) }
            catch {
                cancelTransfer(transfer, reason: Self.reason(error) == "control_lost" ? "control_lost" : "io_error", remote: false)
                return
            }
            touch(transfer); publish()
        case "FILE_REJECT":
            guard transfer.direction == .outgoing else { throw FloatcutSyncProtocolError.invalidState }
            if transfer.phase == .rejected {
                guard transfer.reason == (try message.string("reason")) else { throw FloatcutSyncProtocolError.invalidState }; return
            }
            guard transfer.phase == .offered else { throw FloatcutSyncProtocolError.invalidState }
            terminalSender(transfer, phase: .rejected, reason: try message.string("reason"))
        case "FILE_PROGRESS": try receiveProgress(message, transfer: transfer)
        case "FILE_RESULT": try receiveResult(message, transfer: transfer)
        case "FILE_CANCEL":
            let reason = try message.string("reason")
            if transfer.pendingResult != nil { sendControl(peer, pendingMessage(transfer)); return }
            if transfer.publicationGranted {
                if let result = transfer.terminalResult { sendControl(peer, result) }
                else { sendControl(peer, pendingMessage(transfer)) }; return
            }
            if transfer.phase.isTerminal {
                if transfer.direction == .incoming, let result = transfer.terminalResult { sendControl(peer, result) }
                return
            }
            cancelTransfer(transfer, reason: reason, remote: true)
        default: throw FloatcutSyncProtocolError.invalidState
        }
    }

    func acceptIncoming(_ connection: NWConnection, peer: FloatcutFilePeerContext, candidateStartedAt: TimeInterval) {
        // Root has already started this candidate and authenticated its current
        // certificate/pin and actual negotiated ALPN. Never call start twice.
        let channel = FloatcutFileDataConnection(connection: connection, queue: queue)
        guard ready, !stopped, isCurrent(peer), channel.hasFileALPN, clock.now() < candidateStartedAt + 15 else { channel.close(); onCandidateFinished?(); return }
        candidates[channel.id] = Candidate(channel: channel, deadline: candidateStartedAt + 15, peer: peer)
        channel.onClose = { [weak self, weak channel] _ in
            guard let self, let channel else { return }; self.releaseCandidate(channel.id)
        }
        channel.readPrelude { [weak self, weak channel] message in
            guard let self, let channel else { return }
            self.claimOpen(message, channel: channel, peer: peer)
        }
    }

    func invalidatePeer(_ deviceID: String, reason: String) {
        for transfer in Array(transfers.values) where transfer.peer.deviceID == deviceID && !transfer.phase.isTerminal && !transfer.publicationGranted {
            cancelTransfer(transfer, reason: reason, remote: false)
        }
        for (id, candidate) in Array(candidates) where candidate.peer.deviceID == deviceID { candidate.channel.close(); releaseCandidate(id) }
    }
    func shutdown() {
        guard !stopped else { return }; stopped = true; timer?.cancel(); timer = nil
        for transfer in Array(transfers.values) where !transfer.phase.isTerminal && !transfer.publicationGranted {
            cancelTransfer(transfer, reason: "control_lost", remote: false)
        }
        for (id, candidate) in Array(candidates) { candidate.channel.close(); releaseCandidate(id) }
        publish()
        relinquishIfDrained()
    }

    private func receiveOffer(_ message: FloatcutSyncWireMessage, peer: FloatcutFilePeerContext) throws {
        try message.validateFileOfferStructure()
        let id = try message.string("transfer_id")
        let target = try message.string("target_device_id")
        let size = try message.integer("byte_size")
        let name = try message.string("file_name")
        let hash = try message.string("content_sha256")
        let digest = try message.string("offer_sha256")
        // The codec has checked envelope/types/canonical hashes before dispatch.
        // Semantic precedence is deliberately here, before payload allocation/UI.
        func reject(_ reason: String) { sendControl(peer, FloatcutSyncWireMessage(type: "FILE_REJECT", fields: ["transfer_id": id, "reason": reason])) }
        guard peer.mutualFileCapability else { reject("unsupported"); return }
        guard size <= 8_589_934_592 else { reject("too_large"); return }
        guard target == localDeviceID, FloatcutSyncProtocol.isPortableFileName(name),
              try FloatcutSyncProtocol.fileOfferDigest(transferID: id, controlBindingSHA256: peer.controlBindingSHA256,
                senderDeviceID: peer.deviceID, receiverDeviceID: localDeviceID, byteSize: size, contentSHA256: hash, fileName: name) == digest else {
            reject("invalid_offer"); return
        }
        guard transfers[id] == nil, recentOffers[id] == nil, records[id] == nil else { reject("duplicate_transfer"); return }
        guard receivingEnabled else { retainRejection(id: id, peer: peer, reason: "disabled"); return }
        guard ready, !recoveryFailed, recentOffers.count < 1024, hasSlot(direction: .incoming, peerID: peer.deviceID) else {
            retainRejection(id: id, peer: peer, reason: "busy"); return
        }
        let transfer = Transfer(id: id, direction: .incoming, peer: peer, phase: .offered, fileName: name)
        transfer.manifest = FloatcutFileManifest(transferID: id, senderDeviceID: peer.deviceID, receiverDeviceID: localDeviceID,
                                               fileName: name, byteSize: size, contentSHA256: hash, offerSHA256: digest)
        transfer.offerDeadline = clock.now() + 60
        transfers[id] = transfer; recentOffers[id] = RecentOffer(expires: clock.now() + 600, peer: peer, rejection: nil)
        touch(transfer); publish()
    }

    private func claimOpen(_ message: FloatcutSyncWireMessage, channel: FloatcutFileDataConnection, peer: FloatcutFilePeerContext) {
        reconcile()
        guard let candidate = candidates[channel.id], clock.now() < candidate.deadline,
              message.type == "FILE_OPEN", let id = try? message.string("transfer_id"),
              let transfer = transfers[id], transfer.direction == .incoming, transfer.phase == .connecting,
              transfer.accepted, isActive(transfer), isCurrent(peer), peer == transfer.peer, !transfer.tokenClaimed,
              let deadline = transfer.tokenDeadline, clock.now() < deadline, !hasExpired(transfer),
              let manifest = transfer.manifest, (try? message.string("offer_sha256")) == manifest.offerSHA256,
              (try? message.string("control_binding_sha256")) == peer.controlBindingSHA256,
              let encodedToken = try? message.string("accept_token"),
              let receivedToken = try? FloatcutSyncProtocol.decodeBase64URL(encodedToken, expectedBytes: 32),
              let token = transfer.token, Self.constantTimeEqual(token, receivedToken), let storage = transfer.storage else {
            channel.close(); releaseCandidate(channel.id); return
        }
        // Single-use claim is the serialized linearization point. No payload
        // exists until this branch; invalid connections never consume a token.
        transfer.tokenClaimed = true; transfer.token = nil; transfer.tokenDeadline = nil
        transfer.channel = channel; releaseCandidate(channel.id)
        channel.onClose = { [weak self, weak transfer] reason in
            guard let self, let transfer, self.isActive(transfer), !transfer.publicationGranted else { return }
            self.finishReceiver(transfer, status: "failed", reason: reason)
        }
        submitIO { [self] in
            let created = Result { try storage.createPayload() }
            queue.async { [self] in
                guard isActive(transfer), isCurrent(peer), !hasExpired(transfer) else { cleanup(storage); return }
                switch created {
                case .failure(let error): finishReceiver(transfer, status: "failed", reason: Self.reason(error))
                case .success:
                    transfer.phase = .receiving; transfer.idleDeadline = clock.now() + 30
                    transfer.parser = FloatcutFileBinaryParser(byteSize: manifest.byteSize)
                    transfer.lastProgressAt = clock.now(); transfer.lastProgressBytes = 0
                    sendProgress(transfer, phase: "receiving") // MUST queue before READY.
                    let ready = FloatcutSyncWireMessage(type: "FILE_READY", fields: ["transfer_id": id, "offer_sha256": manifest.offerSHA256, "chunk_size": 262144])
                    channel.sendPrelude(ready) { [weak self, weak transfer] success in
                        guard let self, let transfer, self.isActive(transfer) else { return }
                        if success { self.readReceiver(transfer) }
                        else { self.finishReceiver(transfer, status: "failed", reason: "io_error") }
                    }
                    touch(transfer); publish()
                }
            }
        }
    }

    private func startSenderChannel(_ transfer: Transfer, token: Data) throws {
        let channel = FloatcutFileDataConnection(connection: try connectFile(transfer.peer), queue: queue)
        transfer.channel = channel; transfer.tokenDeadline = clock.now() + 15
        channel.onClose = { [weak self, weak transfer] reason in
            guard let self, let transfer, self.isActive(transfer) else { return }
            if transfer.endSent || transfer.phase == .committing { self.terminalSender(transfer, phase: .unconfirmed, reason: "receipt_missing") }
            else { self.cancelTransfer(transfer, reason: reason == "invalid_data" ? "data_error" : "io_error", remote: false) }
        }
        channel.startOutgoing { [weak self, weak transfer] in
            guard let self, let transfer, self.isActive(transfer), self.isCurrent(transfer.peer), !self.hasExpired(transfer), let manifest = transfer.manifest else {
                channel.close(); return
            }
            transfer.readyDeadline = self.clock.now() + 5; transfer.tokenDeadline = nil
            channel.sendPrelude(FloatcutSyncWireMessage(type: "FILE_OPEN", fields: ["transfer_id": transfer.id,
                "offer_sha256": manifest.offerSHA256, "control_binding_sha256": transfer.peer.controlBindingSHA256,
                "accept_token": FloatcutSyncProtocol.base64URL(token)])) { success in
                guard success, self.isActive(transfer) else { return }
                channel.readPrelude { message in
                    guard self.isActive(transfer), self.isCurrent(transfer.peer), !self.hasExpired(transfer),
                          message.type == "FILE_READY", (try? message.string("transfer_id")) == transfer.id,
                          (try? message.string("offer_sha256")) == manifest.offerSHA256,
                          (try? message.integer("chunk_size")) == 262_144 else {
                        self.cancelTransfer(transfer, reason: "data_error", remote: false); return
                    }
                    transfer.readyDeadline = nil; transfer.idleDeadline = self.clock.now() + 30
                    if transfer.phase != .committing { transfer.phase = .receiving }
                    self.touch(transfer); self.publish(); self.sendNext(transfer)
                }
            }
        }
    }

    private func sendNext(_ transfer: Transfer) {
        guard isActive(transfer), isCurrent(transfer.peer), !hasExpired(transfer), let manifest = transfer.manifest,
              let snapshot = transfer.snapshot, let channel = transfer.channel else { return }
        if transfer.sentOffset == manifest.byteSize {
            do {
                let end = try FloatcutFileBinaryParser.endRecord(size: manifest.byteSize, hash: manifest.contentSHA256)
                transfer.endSent = true; transfer.resultDeadline = clock.now() + 45; transfer.idleDeadline = nil
                channel.send(end) { [weak self, weak transfer] success in
                    guard let self, let transfer, self.isActive(transfer) else { return }
                    if !success { self.terminalSender(transfer, phase: .unconfirmed, reason: "receipt_missing") }
                }
            } catch { cancelTransfer(transfer, reason: "data_error", remote: false) }
            return
        }
        let offset = transfer.sentOffset
        let count = Int(min(Int64(262_144), manifest.byteSize - offset))
        submitIO { [self] in
            let data = Result { try snapshot.dataRecord(offset: offset, count: count) }
            queue.async { [self] in
                guard isActive(transfer), isCurrent(transfer.peer), !hasExpired(transfer) else { return }
                switch data {
                case .failure: cancelTransfer(transfer, reason: "io_error", remote: false)
                case .success(let record):
                    // One bounded payload is queued. Next read starts only after
                    // transport completion, so slow links cannot accumulate data.
                    channel.send(record) { [weak self, weak transfer] success in
                        guard let self, let transfer, self.isActive(transfer) else { return }
                        if !success { self.cancelTransfer(transfer, reason: "io_error", remote: false); return }
                        transfer.sentOffset += Int64(count)
                        transfer.idleDeadline = self.clock.now() + 30
                        self.sendNext(transfer)
                    }
                }
            }
        }
    }

    private func readReceiver(_ transfer: Transfer) {
        guard isActive(transfer), isCurrent(transfer.peer), !hasExpired(transfer), let channel = transfer.channel, let parser = transfer.parser else { return }
        channel.readBinary(maximumLength: parser.receiveBudget) { [weak self, weak transfer] bytes, eof in
            guard let self, let transfer, self.isActive(transfer), !self.hasExpired(transfer) else { return }
            do {
                guard let bytes, !bytes.isEmpty else { throw FloatcutFileFailure.reason("invalid_data") }
                let record = try transfer.parser!.consume(bytes)
                if let record {
                    switch record {
                    case .data(let offset, let bytes):
                        guard let storage = transfer.storage else { throw FloatcutFileFailure.reason("io_error") }
                        // Only a complete structurally validated record renews
                        // idle. A later disk callback cannot extend it again.
                        transfer.idleDeadline = self.clock.now() + 30
                        self.submitIO { [self] in
                            let write = Result { try storage.write(bytes, offset: offset) }
                            self.queue.async { [self] in
                                guard self.isActive(transfer), self.isCurrent(transfer.peer), !self.hasExpired(transfer) else { return }
                                switch write {
                                case .failure(let error): self.finishReceiver(transfer, status: "failed", reason: Self.reason(error))
                                case .success:
                                    transfer.receivedBytes += Int64(bytes.count)
                                    self.touch(transfer); self.publish()
                                    self.emitIntermediateProgress(transfer)
                                    if eof { self.finishReceiver(transfer, status: "failed", reason: "invalid_data") }
                                    else { self.readReceiver(transfer) }
                                }
                            }
                        }
                    case .end(let size, let hash):
                        guard size == transfer.manifest?.byteSize else { throw FloatcutFileFailure.reason("size_mismatch") }
                        guard hash == transfer.manifest?.contentSHA256 else { throw FloatcutFileFailure.reason("hash_mismatch") }
                        // The first valid END ends parsing without waiting for EOF.
                        channel.close(); transfer.idleDeadline = nil; transfer.commitDeadline = self.clock.now() + 30
                        self.preparePublication(transfer)
                    }
                } else if eof { throw FloatcutFileFailure.reason("invalid_data") }
                else { self.readReceiver(transfer) }
            } catch { self.finishReceiver(transfer, status: "failed", reason: Self.reason(error)) }
        }
    }

    private func preparePublication(_ transfer: Transfer) {
        guard let storage = transfer.storage, let manifest = transfer.manifest, var record = transfer.journalRecord else {
            finishReceiver(transfer, status: "failed", reason: "io_error"); return
        }
        submitIO { [self] in
            let verified = Result { try storage.verify(manifest: manifest) }
            queue.async { [self] in
                guard isActive(transfer), isCurrent(transfer.peer), !hasExpired(transfer) else { cleanup(storage); return }
                switch verified {
                case .failure(let error): finishReceiver(transfer, status: "failed", reason: Self.reason(error))
                case .success(let identity):
                    transfer.phase = .committing; transfer.receivedBytes = manifest.byteSize
                    sendProgress(transfer, phase: "committing"); touch(transfer); publish()
                    record.state = "prepared"; record.fileIdentity = identity
                    let preparedRecord = record
                    submitIO { [self] in
                        let prepared = Result { try storage.flushPayload(); try writeJournal(preparedRecord) }
                        queue.async { [self] in
                            guard isActive(transfer), isCurrent(transfer.peer), !hasExpired(transfer) else { cleanup(storage); return }
                            switch prepared {
                            case .failure(let error): finishReceiver(transfer, status: "failed", reason: Self.reason(error))
                            case .success: grantPublication(transfer, storage: storage, record: preparedRecord)
                            }
                        }
                    }
                }
            }
        }
    }

    private func grantPublication(_ transfer: Transfer, storage: FloatcutFileStorage, record: FloatcutFileTransferJournal.Record) {
        records[transfer.id] = record; transfer.journalRecord = record
        // The executor rechecks authorization and every original
        // deadline immediately before its one irrevocable grant.
        guard isCurrent(transfer.peer), !hasExpired(transfer), !transfer.publicationGranted else {
            finishReceiver(transfer, status: "failed", reason: "io_error"); return
        }
        transfer.publicationGranted = true; transfer.commitDeadline = nil; transfer.totalDeadline = nil
        submitIO { [self] in
            let publication = Result { try storage.publish() }
            queue.async { [self] in
                // A grant owns its actual result, even after shutdown,
                // revocation or a newer engine epoch. Never delete final.
                switch publication {
                case .failure(let error):
                    if storage.didPublish {
                        transfer.reason = "receipt_missing"; touch(transfer); publish()
                        // Prepared evidence remains; reconcile on restart.
                    } else { finishReceiver(transfer, status: "failed", reason: Self.reason(error), afterGrant: true) }
                case .success:
                    finishReceiver(transfer, status: "saved", reason: nil, afterGrant: true)
                }
            }
        }
    }

    private func receiveProgress(_ message: FloatcutSyncWireMessage, transfer: Transfer) throws {
        guard transfer.direction == .outgoing, let manifest = transfer.manifest,
              try message.string("offer_sha256") == manifest.offerSHA256 else { throw FloatcutSyncProtocolError.invalidState }
        // Once a terminal result exists, late progress cannot alter presentation.
        if transfer.phase.isTerminal { return }
        guard transfer.accepted else { throw FloatcutSyncProtocolError.invalidState }
        let bytes = try message.integer("received_bytes")
        let phase = try message.string("phase")
        guard bytes >= transfer.receivedBytes, bytes <= manifest.byteSize,
              bytes % 262_144 == 0 || bytes == manifest.byteSize,
              phase == "receiving" || (phase == "committing" && bytes == manifest.byteSize),
              !(transfer.progressPhase == "committing" && phase != "committing") else { throw FloatcutSyncProtocolError.invalidState }
        let changed = bytes != transfer.receivedBytes || phase != transfer.progressPhase
        transfer.receivedBytes = bytes; transfer.progressPhase = phase
        if phase == "committing" { transfer.phase = .committing }
        // Initial receiving/0 may legally precede READY. Keep connecting until
        // the actual data READY rather than inferring permission from progress.
        if changed { touch(transfer); publish() }
    }

    private func receiveResult(_ message: FloatcutSyncWireMessage, transfer: Transfer) throws {
        guard transfer.direction == .outgoing, let manifest = transfer.manifest,
              try message.string("offer_sha256") == manifest.offerSHA256 else { throw FloatcutSyncProtocolError.invalidState }
        let status = try message.string("status")
        if let previous = transfer.terminalResult {
            guard Self.resultsAgree(previous, message) else { throw FloatcutSyncProtocolError.invalidState }; return
        }
        switch status {
        case "saved":
            guard transfer.accepted, try message.integer("byte_size") == manifest.byteSize,
                  try message.string("content_sha256") == manifest.contentSHA256 else { throw FloatcutSyncProtocolError.invalidState }
            transfer.terminalResult = message; transfer.receivedBytes = manifest.byteSize
            terminalSender(transfer, phase: .saved, reason: nil)
        case "failed", "cancelled":
            transfer.terminalResult = message
            terminalSender(transfer, phase: status == "failed" ? .failed : .cancelled, reason: try message.string("reason"))
        case "pending":
            let phase = try message.string("phase")
            if transfer.phase.isTerminal { return }
            if phase == "committing" { transfer.phase = .committing; touch(transfer); publish() }
        case "unknown":
            guard transfer.phase == .unconfirmed else { throw FloatcutSyncProtocolError.invalidState }
            transfer.reason = "receipt_missing"; touch(transfer); publish()
        default: throw FloatcutSyncProtocolError.invalidState
        }
    }

    private func answerStatus(id: String, hash: String, peer: FloatcutFilePeerContext) throws {
        guard ready else { throw FloatcutSyncProtocolError.invalidState }
        if let transfer = transfers[id], transfer.direction == .incoming, sameTrust(transfer.peer, peer), transfer.manifest?.offerSHA256 == hash {
            if !transfer.phase.isTerminal || transfer.pendingResult != nil { sendControl(peer, pendingMessage(transfer)); return }
            // A terminal window is UI history, not a renewed receipt. Fall
            // through to retained durable author/offer/expiry checks below.
        }
        if let record = records[id], record.direction == .incoming, matches(record, peer: peer), record.manifest.offerSHA256 == hash,
           record.terminalAtMilliseconds.map({ wallClock() < $0 + 86_400_000 }) ?? false {
            sendControl(peer, resultMessage(record)); return
        }
        sendControl(peer, unknownMessage(id: id, hash: hash))
    }

    private func finishReceiver(_ transfer: Transfer, status: String, reason: String?, afterGrant: Bool = false) {
        guard transfer.direction == .incoming, transfer.terminalResult == nil,
              (!transfer.publicationGranted || afterGrant) else { return }
        if transfer.phase.isTerminal { return }
        transfer.workInvalidated = true
        transfer.token = nil; transfer.channel?.close(); transfer.channel = nil
        transfer.offerDeadline = nil; transfer.tokenDeadline = nil; transfer.idleDeadline = nil
        transfer.commitDeadline = nil; transfer.totalDeadline = nil
        transfer.reason = reason
        if status != "saved", !transfer.accepted {
            transfer.phase = status == "cancelled" ? .cancelled : .failed
            touch(transfer); publish()
        }
        let fields: [String: Any]
        if status == "saved", let manifest = transfer.manifest {
            fields = ["transfer_id": transfer.id, "offer_sha256": manifest.offerSHA256, "status": "saved",
                      "byte_size": manifest.byteSize, "content_sha256": manifest.contentSHA256]
        } else {
            fields = ["transfer_id": transfer.id, "offer_sha256": transfer.manifest?.offerSHA256 ?? "",
                      "status": status, "reason": reason ?? "io_error"]
        }
        let result = FloatcutSyncWireMessage(type: "FILE_RESULT", fields: fields)
        guard transfer.accepted, var record = transfer.journalRecord else {
            transfer.terminalResult = result; releaseSlot(transfer)
            if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, result) }
            if let storage = transfer.storage { cleanup(storage) }
            touch(transfer); publish(); return
        }
        record.state = status; record.reason = reason; record.terminalAtMilliseconds = wallClock()
        if status != "saved", !transfer.publicationGranted, let storage = transfer.storage {
            // Cancellation/failure releases private bytes even if the journal
            // is temporarily unwritable; keeping an unlinked fd would retain
            // its disk space and could prevent receipt persistence indefinitely.
            cleanup(storage); transfer.storage = nil
        }
        transfer.pendingResultPhase = transfer.publicationGranted || transfer.progressPhase == "committing" ? "committing"
            : (transfer.phase == .receiving ? "receiving" : "accepted")
        transfer.pendingResultRecord = record; transfer.pendingResult = result
        transfer.phase = .committing // Terminal metadata durability is still in progress.
        touch(transfer); publish()
        persistReceiverOutcome(transfer)
    }

    private func persistReceiverOutcome(_ transfer: Transfer) {
        guard !transfer.persistenceInFlight, let record = transfer.pendingResultRecord, let result = transfer.pendingResult else { return }
        transfer.persistenceInFlight = true
        submitIO { [self] in
            let persisted = Result { try writeJournal(record) }
            queue.async { [self] in
                transfer.persistenceInFlight = false
                switch persisted {
                case .failure:
                    // Neither success nor a failed/cancelled terminal receipt
                    // is confirmed until its exact outcome is durable. Keep
                    // accepted/prepared evidence and the reserved receipt slot.
                    transfer.phase = .unconfirmed; transfer.reason = "receipt_missing"
                    touch(transfer); publish()
                    queue.asyncAfter(deadline: .now() + 1) { [weak self, weak transfer] in
                        guard let self, let transfer, !self.stopped, !self.ownershipRelinquished else { return }
                        self.persistReceiverOutcome(transfer)
                    }
                case .success:
                    records[transfer.id] = record; transfer.journalRecord = record; transfer.terminalResult = result
                    transfer.pendingResult = nil; transfer.pendingResultRecord = nil; transfer.pendingResultPhase = nil
                    transfer.phase = record.state == "saved" ? .saved : (record.state == "cancelled" ? .cancelled : .failed)
                    transfer.reason = record.reason
                    releaseSlot(transfer)
                    if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, result) }
                    if let storage = transfer.storage { cleanup(storage) }
                    transfer.storage = nil
                    touch(transfer); publish()
                }
            }
        }
    }

    private func cancelTransfer(_ transfer: Transfer, reason: String, remote: Bool) {
        if transfer.pendingResult != nil {
            if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, pendingMessage(transfer)) }
            return
        }
        guard !transfer.phase.isTerminal else { return }
        if transfer.publicationGranted {
            if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, transfer.terminalResult ?? pendingMessage(transfer)) }
            return
        }
        let oldPhase = transfer.phase
        if !remote, isCurrent(transfer.peer), !stopped, transfer.manifest != nil,
           transfer.direction == .incoming || transfer.offerSent {
            send(transfer, "FILE_CANCEL", ["reason": reason])
        }
        if transfer.direction == .outgoing {
            if transfer.endSent || transfer.phase == .committing { terminalSender(transfer, phase: .unconfirmed, reason: "receipt_missing") }
            else {
                let phase: FloatcutFileTransferPhase = reason == "user_cancelled" || reason == "revoked" ? .cancelled : .failed
                terminalSender(transfer, phase: phase, reason: reason == "user_cancelled" && remote ? "peer_cancelled" : reason)
            }
            return
        }
        var status = "failed"; var resultReason = "io_error"
        switch reason {
        case "user_cancelled": status = "cancelled"; resultReason = remote ? "peer_cancelled" : "user_cancelled"
        case "revoked": status = "cancelled"; resultReason = "revoked"
        case "io_error": resultReason = "io_error"
        case "data_error": resultReason = "invalid_data"
        case "control_lost": resultReason = "control_lost"
        case "timeout": resultReason = oldPhase == .receiving ? "data_timeout" : (oldPhase == .committing ? "io_error" : "channel_timeout")
        default: resultReason = "io_error"
        }
        finishReceiver(transfer, status: status, reason: resultReason)
    }

    private func terminalSender(_ transfer: Transfer, phase: FloatcutFileTransferPhase, reason: String?) {
        transfer.workInvalidated = true
        transfer.phase = phase; transfer.reason = reason; transfer.token = nil
        transfer.channel?.close(); transfer.channel = nil
        releaseSlot(transfer); retireSnapshot(transfer)
        touch(transfer); publish()
        if phase != .unconfirmed {
            records.removeValue(forKey: transfer.id)
            submitIO { [journal] in try? journal.removeOutbound(transfer.id) }
        }
    }
    private func localFailure(_ transfer: Transfer, reason: String) { terminalSender(transfer, phase: .failed, reason: reason) }

    private func rejectOffer(_ transfer: Transfer, reason: String) {
        guard transfer.direction == .incoming, transfer.phase == .offered, !transfer.accepted else { return }
        let rejection = FloatcutSyncWireMessage(type: "FILE_REJECT", fields: ["transfer_id": transfer.id, "reason": reason])
        transfer.phase = .rejected; transfer.reason = reason; transfer.token = nil; releaseSlot(transfer)
        if var recent = recentOffers[transfer.id] { recent.rejection = rejection; recentOffers[transfer.id] = recent }
        if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, rejection) }
        if let storage = transfer.storage { cleanup(storage) }; transfer.storage = nil
        touch(transfer); publish()
    }
    private func retainRejection(id: String, peer: FloatcutFilePeerContext, reason: String) {
        let message = FloatcutSyncWireMessage(type: "FILE_REJECT", fields: ["transfer_id": id, "reason": reason])
        if recentOffers.count < 1024 { recentOffers[id] = RecentOffer(expires: clock.now() + 600, peer: peer, rejection: message) }
        sendControl(peer, message)
    }
    private func releaseSlot(_ transfer: Transfer) { transfer.quotaReserved = false }
    private func releaseCandidate(_ id: UUID) { if candidates.removeValue(forKey: id) != nil { onCandidateFinished?() } }
    private func send(_ transfer: Transfer, _ type: String, _ fields: [String: Any]) {
        var fields = fields; fields["transfer_id"] = transfer.id
        if isCurrent(transfer.peer), !stopped { sendControl(transfer.peer, FloatcutSyncWireMessage(type: type, fields: fields)) }
    }
    private func sendProgress(_ transfer: Transfer, phase: String) {
        transfer.progressPhase = phase
        send(transfer, "FILE_PROGRESS", ["offer_sha256": transfer.manifest!.offerSHA256, "received_bytes": transfer.receivedBytes, "phase": phase])
        transfer.lastProgressAt = clock.now(); transfer.lastProgressBytes = transfer.receivedBytes
    }
    private func emitIntermediateProgress(_ transfer: Transfer) {
        guard transfer.direction == .incoming, transfer.phase == .receiving, transfer.receivedBytes > transfer.lastProgressBytes,
              clock.now() >= transfer.lastProgressAt + 1 else { return }
        sendProgress(transfer, phase: "receiving")
    }
    private func pendingMessage(_ transfer: Transfer) -> FloatcutSyncWireMessage {
        let phase: String
        if let pendingPhase = transfer.pendingResultPhase { phase = pendingPhase }
        else if transfer.publicationGranted || transfer.phase == .committing { phase = "committing" }
        else if transfer.phase == .receiving { phase = "receiving" }
        else if transfer.accepted { phase = "accepted" }
        else { phase = "offered" }
        return FloatcutSyncWireMessage(type: "FILE_RESULT", fields: ["transfer_id": transfer.id,
            "offer_sha256": transfer.manifest!.offerSHA256, "status": "pending", "phase": phase])
    }
    private func resultMessage(_ record: FloatcutFileTransferJournal.Record) -> FloatcutSyncWireMessage {
        var fields: [String: Any] = ["transfer_id": record.manifest.transferID, "offer_sha256": record.manifest.offerSHA256, "status": record.state]
        if record.state == "saved" { fields["byte_size"] = record.manifest.byteSize; fields["content_sha256"] = record.manifest.contentSHA256 }
        else { fields["reason"] = record.reason ?? "io_error" }
        return FloatcutSyncWireMessage(type: "FILE_RESULT", fields: fields)
    }
    private func unknownMessage(id: String, hash: String) -> FloatcutSyncWireMessage {
        FloatcutSyncWireMessage(type: "FILE_RESULT", fields: ["transfer_id": id, "offer_sha256": hash, "status": "unknown", "reason": "receipt_missing"])
    }
    private func makeRecord(_ transfer: Transfer, state: String) -> FloatcutFileTransferJournal.Record {
        FloatcutFileTransferJournal.Record(manifest: transfer.manifest!, direction: transfer.direction, peerID: transfer.peer.deviceID,
            peerPin: transfer.peer.certificateSHA256, trustGeneration: transfer.peer.trustGeneration, peerName: transfer.peer.name,
            state: state, reason: nil, destinationDirectory: nil, destinationIdentity: nil, stagingLeaf: nil, finalLeaf: nil,
            fileIdentity: nil, terminalAtMilliseconds: state == "outbound" ? wallClock() : nil)
    }
    private func persistAbandoned(_ transfer: Transfer, record: FloatcutFileTransferJournal.Record) {
        var terminal = record; terminal.state = "failed"; terminal.reason = "control_lost"; terminal.terminalAtMilliseconds = wallClock()
        if transfer.phase == .cancelled { terminal.state = "cancelled"; terminal.reason = transfer.reason ?? "user_cancelled" }
        receiptReservations.insert(transfer.id)
        submitIO { [self] in
            let result = Result { try writeJournal(terminal) }
            queue.async { [self] in if case .success = result { records[transfer.id] = terminal; receiptReservations.insert(transfer.id) } }
        }
    }
    private func retireSnapshot(_ transfer: Transfer) {
        guard let snapshot = transfer.snapshot else { return }; transfer.snapshot = nil; cleanup(snapshot)
    }
    private func submitIO(_ work: @escaping () -> Void) {
        pendingDiskWork += 1
        workers.addOperation { [self] in
            work()
            // The job queued its decision callback first. That callback may
            // enqueue a successor or stale cleanup before this count is retired.
            queue.async { [self] in
                pendingDiskWork -= 1
                relinquishIfDrained()
            }
        }
    }
    private func relinquishIfDrained() {
        guard stopped, pendingDiskWork == 0, !relinquishing, !ownershipRelinquished else { return }
        relinquishing = true
        workers.addOperation { [self] in
            journal.relinquishOwnership()
            queue.async { [self] in
                ownershipRelinquished = true; relinquishing = false
                publish()
            }
        }
    }
    private func cleanup(_ snapshot: FloatcutFileStorage.Snapshot) { submitIO { snapshot.remove() } }
    private func cleanup(_ storage: FloatcutFileStorage) { submitIO { storage.cleanup() } }
    private func writeJournal(_ record: FloatcutFileTransferJournal.Record) throws {
        try beforeJournalWrite?(record)
        try journal.put(record)
    }
    private func sameTrust(_ a: FloatcutFilePeerContext, _ b: FloatcutFilePeerContext) -> Bool {
        a.deviceID == b.deviceID && a.certificateSHA256 == b.certificateSHA256 && a.trustGeneration == b.trustGeneration
    }
    private func matches(_ record: FloatcutFileTransferJournal.Record, peer: FloatcutFilePeerContext) -> Bool {
        record.peerID == peer.deviceID && record.peerPin == peer.certificateSHA256 && record.trustGeneration == peer.trustGeneration
    }
    private func isCurrent(_ peer: FloatcutFilePeerContext) -> Bool { !stopped && peer.engineEpoch == epoch && lookupPeer(peer.deviceID) == peer }
    private func isActive(_ transfer: Transfer) -> Bool {
        transfers[transfer.id] === transfer && !transfer.phase.isTerminal && !transfer.workInvalidated
    }
    private func hasSlot(direction: FloatcutFileTransferDirection, peerID: String, excluding: String? = nil) -> Bool {
        let active = transfers.values.filter { $0.id != excluding && $0.direction == direction && $0.quotaReserved }
        return active.count < 4 && !active.contains { $0.peer.deviceID == peerID }
    }
    private func hasExpired(_ transfer: Transfer) -> Bool {
        if transfer.publicationGranted { return false }
        let now = clock.now()
        return [transfer.offerDeadline, transfer.tokenDeadline, transfer.readyDeadline, transfer.idleDeadline,
                transfer.totalDeadline, transfer.commitDeadline].compactMap { $0 }.contains { now >= $0 }
    }
    func reconcileDeadlines() { reconcile() }
    var allowsReceiving: Bool { get { receivingEnabled } set { receivingEnabled = newValue } }
    private func reconcile() {
        let now = clock.now()
        for (id, offer) in Array(recentOffers) where now >= offer.expires { recentOffers.removeValue(forKey: id) }
        let epochNow = wallClock()
        for (id, record) in Array(records) where record.terminalAtMilliseconds.map({ epochNow >= $0 + 86_400_000 }) ?? false {
            records.removeValue(forKey: id); receiptReservations.remove(id)
        }
        for (id, candidate) in Array(candidates) where now >= candidate.deadline || !isCurrent(candidate.peer) {
            candidate.channel.close(); releaseCandidate(id)
        }
        for transfer in Array(transfers.values) where !transfer.phase.isTerminal {
            if transfer.publicationGranted { continue }
            if !isCurrent(transfer.peer) { cancelTransfer(transfer, reason: "control_lost", remote: false); continue }
            if transfer.direction == .outgoing, let resultDeadline = transfer.resultDeadline, now >= resultDeadline {
                terminalSender(transfer, phase: .unconfirmed, reason: "receipt_missing"); continue
            }
            if hasExpired(transfer) {
                if transfer.direction == .incoming, transfer.phase == .offered { rejectOffer(transfer, reason: "timeout") }
                else if transfer.commitDeadline.map({ now >= $0 }) ?? false { finishReceiver(transfer, status: "failed", reason: "io_error") }
                else { cancelTransfer(transfer, reason: "timeout", remote: false) }
                continue
            }
            emitIntermediateProgress(transfer)
        }
    }
    private func touch(_ transfer: Transfer) { revision &+= 1; transfer.revision = revision }
    private func publish() {
        // Keep recent windows bounded. Durable receiver receipts and outbound
        // recovery records remain separately authoritative after UI retirement.
        let history = transfers.values.filter {
            $0.phase.isTerminal && !$0.quotaReserved && $0.pendingResult == nil
        }.sorted { $0.revision > $1.revision }
        for transfer in history.dropFirst(128) { transfers.removeValue(forKey: transfer.id) }
        let snapshots = transfers.values.sorted { $0.revision > $1.revision }.prefix(128).map { transfer in
            FloatcutFileTransferSnapshot(id: transfer.id, direction: transfer.direction, phase: transfer.phase,
                peerDeviceID: transfer.peer.deviceID, peerName: transfer.peer.name, fileName: transfer.fileName,
                byteSize: transfer.manifest?.byteSize ?? 0, receivedBytes: transfer.receivedBytes,
                revision: transfer.revision, engineEpoch: epoch, localDestination: transfer.destination, reason: transfer.reason,
                hasVerifiedEnd: transfer.progressPhase == "committing" || transfer.phase == .saved)
        }
        onSnapshots(Array(snapshots))
    }
    private static func reason(_ error: Error) -> String { (error as? FloatcutFileFailure)?.wireReason ?? "io_error" }
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }; var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }; return difference == 0
    }
    private static func resultsAgree(_ a: FloatcutSyncWireMessage, _ b: FloatcutSyncWireMessage) -> Bool {
        for key in ["transfer_id", "offer_sha256", "status", "reason", "byte_size", "content_sha256"] {
            if String(describing: a.fields[key]) != String(describing: b.fields[key]) { return false }
        }
        return true
    }
}
