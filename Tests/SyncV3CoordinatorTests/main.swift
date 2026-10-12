import AppKit
import Darwin
import Foundation
import Network

struct CoordinatorTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
    guard try condition() else { throw CoordinatorTestFailure(detail) }
}
/// Keep the real main executor servicing coordinator publication/delegate work.
func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.005))) }
}
func wait(_ detail: String, timeout: TimeInterval = 15, until predicate: () -> Bool) throws {
    let end = Date().addingTimeInterval(timeout)
    while !predicate() {
        guard Date() < end else { throw CoordinatorTestFailure("Timed out: \(detail)") }
        pump(0.005)
    }
}

final class CoordinatorTestClock: FloatcutSyncElapsedClock {
    private let lock = NSLock()
    private let base = FloatcutSyncContinuousClock()
    private var offset: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return base.now() + offset }
    func advance(_ seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
}
final class Observations {
    let lock = NSLock()
    var codes: [Int: String] = [:]
    var confirmations: [Int: (Bool) -> Void] = [:]
    var wire: [(Int, String, String)] = []
    var heldText: (() -> Void)?
    var queuedStates: [FloatcutSyncCoordinatorTestState] = []
    var diagnostics: [String] = []
    func withLock<T>(_ body: (Observations) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(self)
    }
}
final class ClipboardRecorder: NSObject, FloatcutSyncClipboardDelegate {
    var text: [String] = []
    func syncCoordinator(_ coordinator: FloatcutSyncCoordinator, didReceiveText value: String,
                         peerName: String, peerDeviceID: String, clipID: String) -> String {
        text.append(value); return "applied"
    }
    func syncCoordinator(_ coordinator: FloatcutSyncCoordinator, didReceiveImage data: Data,
                         contentType: String, peerName: String, peerDeviceID: String, clipID: String) -> String { "unsupported" }
    func syncCoordinatorIsClipboardPaused(_ coordinator: FloatcutSyncCoordinator) -> Bool { false }
}

/// Every fixture creates unique Keychain identities, UserDefaults domains and
/// temporary storage; it never reads/writes application trust or preferences.
final class Fixture {
    let root: URL
    let observations = Observations()
    var defaults: [UserDefaults] = []
    var suites: [String] = []
    var stores: [FloatcutSyncIdentityStore] = []
    var hooks: [FloatcutSyncCoordinatorTestHooks] = []
    var coordinators: [FloatcutSyncCoordinator] = []
    var delegates: [ClipboardRecorder] = []
    var clocks: [CoordinatorTestClock] = []
    var workers: [OperationQueue] = []
    var closed = false

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/FloatcutV3Coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for index in 0..<2 {
                let suite = "de.meierkarsten.floatcut.coordinator-test.\(UUID().uuidString)"
                let preferences = UserDefaults(suiteName: suite)!
                let store = FloatcutSyncIdentityStore(defaults: preferences, keyTag: Data("\(suite).key".utf8),
                                                      certificateLabel: "Floatcut Coordinator Test \(suite)")
                // Register cleanup ownership before any Keychain operation.
                suites.append(suite); defaults.append(preferences); stores.append(store)
                let hook = FloatcutSyncCoordinatorTestHooks(), clock = CoordinatorTestClock(), io = OperationQueue()
                io.maxConcurrentOperationCount = 4
                hook.clock = clock; hook.diskWorkers = io
                hook.approvePairing = { _, complete in complete(true) }
                hook.confirmCode = { [observations] code, _, complete in
                    observations.withLock { $0.codes[index] = code; $0.confirmations[index] = complete }
                }
                hook.onWireEvent = { [observations] direction, type in
                    observations.withLock { $0.wire.append((index, direction, type)) }
                }
                hook.onDiagnostic = { [observations] event, _ in observations.withLock { $0.diagnostics.append(event) } }
                let coordinator = FloatcutSyncCoordinator.testInstance(defaults: preferences,
                    directory: root.appendingPathComponent("peer\(index)"), identityStore: store, hooks: hook)
                let delegate = ClipboardRecorder()
                coordinator.clipboardDelegate = delegate
                coordinator.deviceName = "Coordinator client \(index)"
                hooks.append(hook); clocks.append(clock); workers.append(io)
                coordinators.append(coordinator); delegates.append(delegate)
                coordinator.setEnabled(true)
                try require(coordinator.isEnabled, "Isolated coordinator identity failed: \(coordinator.statusText)")
            }
            try wait("two localhost production listeners and isolated journals") {
                coordinators.allSatisfy { $0.testState()?.port != nil && $0.testState()?.fileEngineReady == true }
            }
        } catch {
            for (index, coordinator) in coordinators.enumerated() {
                fputs("Boot peer\(index): status=\(coordinator.statusText), port=\(String(describing: coordinator.testState()?.port)), ready=\(String(describing: coordinator.testState()?.fileEngineReady))\n", stderr)
            }
            fputs("Diagnostics: \(observations.withLock { $0.diagnostics })\n", stderr)
            close(); throw error
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        workers.forEach { $0.isSuspended = false }
        coordinators.forEach { $0.testStopAndWait() }
        workers.forEach { $0.waitUntilAllOperationsAreFinished() }
        for (index, store) in stores.enumerated() {
            do { try store.reset() }
            catch { fputs("Test identity cleanup failed: \(error)\n", stderr) }
            defaults[index].removePersistentDomain(forName: suites[index])
        }
        try? FileManager.default.removeItem(at: root)
    }
    deinit { close() }
    func discoverBoth() throws {
        for index in 0..<2 {
            let other = coordinators[1-index]
            let port = try unwrap(other.testState()?.port, "listener port")
            coordinators[index].testDiscover(deviceID: other.localDeviceID, name: other.deviceName, port: port)
        }
        try wait("synthetic localhost discovery published") { coordinators.allSatisfy { $0.discoveredPeers.count == 1 } }
    }
    func pair(initiatorHasSmallerUUID: Bool) throws -> (Int, Int) {
        try discoverBoth()
        let smaller = coordinators[0].localDeviceID < coordinators[1].localDeviceID ? 0 : 1
        let initiator = initiatorHasSmallerUUID ? smaller : 1-smaller, acceptor = 1-initiator
        coordinators[initiator].pair(deviceID: coordinators[acceptor].localDeviceID)
        try wait("both actual commit/reveal SAS prompts") { observations.withLock { $0.codes.count == 2 } }
        try require(observations.withLock { $0.codes[0] == $0.codes[1] }, "Production pairing comparison codes differ")
        try require(coordinators.allSatisfy { $0.allPairedPeers().isEmpty && $0.testState()?.contexts.isEmpty == true },
                    "Production pairing trusted a peer before local SAS approval")
        observations.withLock { $0.confirmations[initiator] }?(true)
        try wait("first actual PAIR_CONFIRM sent") {
            observations.withLock { $0.wire.contains { $0.0 == initiator && $0.1 == "send" && $0.2 == "PAIR_CONFIRM" } }
        }
        pump(0.05)
        try require(coordinators.allSatisfy { $0.allPairedPeers().isEmpty }, "One confirmation granted trust before the second approval")
        observations.withLock { $0.confirmations[acceptor] }?(true)
        try wait("both production peers trusted and file contexts available") {
            coordinators.allSatisfy { $0.allPairedPeers().count == 1 && $0.testState()?.contexts.count == 1 }
        }
        let left = coordinators[0].testState()!.connections.first { $0.trusted }!
        let right = coordinators[1].testState()!.connections.first { $0.trusted }!
        try require(left.binding != nil && left.binding == right.binding, "Production HELLO binding differs across TLS peers")
        try require(left.transcript != nil && left.transcript == right.transcript, "Production commit/reveal transcript differs")
        try require(left.initiator == (initiator == 0) && right.initiator == (initiator == 1), "Pairing roles changed with UUID ordering")
        return (initiator, acceptor)
    }
    func offer(sender: Int, name: String, bytes: Int = 768 * 1024) throws -> (String, Data, URL) {
        let receiver = 1-sender
        let source = root.appendingPathComponent(name)
        let payload = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })
        try payload.write(to: source)
        try wait("available production client target") {
            coordinators[sender].fileClientTargets.contains { $0.id == coordinators[receiver].localDeviceID && $0.isAvailable }
        }
        let target = coordinators[sender].fileClientTargets.first { $0.id == coordinators[receiver].localDeviceID && $0.isAvailable }!
        coordinators[sender].sendFile(url: source, peer: target)
        try wait("production FILE_OFFER received with consent pending") {
            coordinators[receiver].fileTransfers.contains { $0.fileName == name && $0.phase == .offered }
        }
        let transfer = coordinators[receiver].fileTransfers.first { $0.fileName == name }!
        let destination = root.appendingPathComponent("received-\(transfer.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try require(transfer.receivedBytes == 0, "Data arrived before recipient consent")
        return (transfer.id, payload, destination)
    }
}
func unwrap<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else { throw CoordinatorTestFailure("Missing \(description)") }; return value
}
func transfer(_ fixture: Fixture, peer: Int, id: String) -> FloatcutFileTransferSnapshot? {
    fixture.coordinators[peer].fileTransfers.first { $0.id == id }
}

func testPairingAndFiles(smallerInitiator: Bool) throws {
    let fixture = try Fixture(); defer { fixture.close() }
    let (sender, receiver) = try fixture.pair(initiatorHasSmallerUUID: smallerInitiator)
    let source = fixture.coordinators[sender], sink = fixture.coordinators[receiver]
    let before = fixture.observations.withLock { $0.wire.count }
    try source.testSendPairingStatuses(to: sink.localDeviceID)
    try wait("completed PAIR_STATUS and PAIR_CONFIRM received") {
        fixture.observations.withLock { state in state.wire.dropFirst(before).filter { $0.0 == receiver && $0.1 == "receive" && $0.2.hasPrefix("PAIR_") }.count >= 4 }
    }
    pump(0.15)
    let count = fixture.observations.withLock { $0.wire.count }
    pump(0.15)
    try require(fixture.observations.withLock { $0.wire.count } == count, "Completed production pairing entered an infinite status reply loop")
    try require(source.testState()?.contexts.count == 1 && sink.testState()?.contexts.count == 1,
                "Late pairing confirmation/status killed a trusted production connection")
    source.sendAcceptedLocalText("V3 production clipboard")
    try wait("production clipboard delegate received text") { fixture.delegates[receiver].text == ["V3 production clipboard"] }

    let (id, payload, destination) = try fixture.offer(sender: sender, name: "consent-\(smallerInitiator).bin")
    let incoming = transfer(fixture, peer: receiver, id: id)!
    let wrongEpoch = incoming.engineEpoch &+ 1
    sink.acceptFileTransfer(id: id, directory: destination, revision: incoming.revision, engineEpoch: wrongEpoch)
    sink.rejectFileTransfer(id: id, revision: incoming.revision, engineEpoch: wrongEpoch)
    sink.cancelFileTransfer(id: id, revision: incoming.revision, engineEpoch: wrongEpoch)
    _ = sink.testState(); pump(0.1)
    try require(transfer(fixture, peer: receiver, id: id)?.phase == .offered, "Wrong-epoch incoming UI action changed a production transfer")
    let outgoing = transfer(fixture, peer: sender, id: id)!
    source.cancelFileTransfer(id: id, revision: outgoing.revision, engineEpoch: outgoing.engineEpoch &+ 1)
    _ = source.testState(); pump(0.05)
    try require(transfer(fixture, peer: sender, id: id)?.phase == .offered, "Wrong-epoch outgoing cancellation changed a production transfer")
    try require((try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)).isEmpty,
                "Recipient destination changed before consent")
    sink.acceptFileTransfer(id: id, directory: destination, revision: incoming.revision, engineEpoch: incoming.engineEpoch)
    try wait("actual production control + separate native TLS file channel completed", timeout: 30) {
        transfer(fixture, peer: sender, id: id)?.phase == .saved && transfer(fixture, peer: receiver, id: id)?.phase == .saved
    }
    let saved = transfer(fixture, peer: receiver, id: id)!
    try require(try Data(contentsOf: unwrap(saved.localDestination, "saved path")) == payload, "Production file transfer bytes differ")
    try require(transfer(fixture, peer: sender, id: id)?.percentage == 100, "Sender did not publish confirmed 100% progress")

    if smallerInitiator {
        let (rejectedID, _, rejectedDirectory) = try fixture.offer(sender: sender, name: "reject.bin", bytes: 17)
        let offer = transfer(fixture, peer: receiver, id: rejectedID)!
        sink.rejectFileTransfer(id: rejectedID, revision: offer.revision, engineEpoch: offer.engineEpoch)
        try wait("recipient rejection reached sender") { transfer(fixture, peer: sender, id: rejectedID)?.phase == .rejected }
        try require((try FileManager.default.contentsOfDirectory(at: rejectedDirectory, includingPropertiesForKeys: nil)).isEmpty, "Rejected transfer wrote a destination file")
        let (cancelledID, _, _) = try fixture.offer(sender: sender, name: "cancel.bin", bytes: 19)
        let cancelled = transfer(fixture, peer: receiver, id: cancelledID)!
        sink.cancelFileTransfer(id: cancelledID, revision: cancelled.revision, engineEpoch: cancelled.engineEpoch)
        try wait("recipient cancellation reached sender") { transfer(fixture, peer: sender, id: cancelledID)?.phase == .cancelled }
    }
    print("PASS actual coordinator TLS/commit-reveal, bounded status convergence, clipboard and consented file channel (initiator UUID \(smallerInitiator ? "smaller" : "larger"))")
}

func testQueuedAuthorization() throws {
    let fixture = try Fixture(); defer { fixture.close() }
    let (sender, receiver) = try fixture.pair(initiatorHasSmallerUUID: true)
    let (id, _, _) = try fixture.offer(sender: sender, name: "queued-revocation.bin", bytes: 257)
    let coordinator = fixture.coordinators[receiver], deviceID = fixture.coordinators[sender].localDeviceID
    let original = coordinator.testState()!.contexts[deviceID]!
    let release = coordinator.testHoldAuthorityQueue()
    defer { release() }
    coordinator.setPeerEnabled(deviceID: deviceID, enabled: false)
    try require(coordinator.pairedPeer(deviceID)?.enabled == true,
                "Disable persisted outside the held authority transaction, before advancing its generation")
    coordinator.testCaptureQueuedState { [observations = fixture.observations] state in observations.withLock { $0.queuedStates.append(state) } }
    coordinator.setPeerEnabled(deviceID: deviceID, enabled: true)
    coordinator.testCaptureQueuedState { [observations = fixture.observations] state in observations.withLock { $0.queuedStates.append(state) } }
    release()
    try wait("queued authorization snapshots") { fixture.observations.withLock { $0.queuedStates.count == 2 } }
    let states = fixture.observations.withLock { $0.queuedStates }
    try require(states[0].generations[deviceID] == original.peerGeneration &+ 1,
                "Disable did not increment peer authority inside its transaction")
    try require(states[1].generations[deviceID] == original.peerGeneration &+ 2,
                "Queued re-enable lost a peer authority generation")
    try require(!states[0].enabledDeviceIDs.contains(deviceID) && states[1].enabledDeviceIDs.contains(deviceID),
                "Queued disable/enable persistence overtook its corresponding authority generation")
    try require(states.allSatisfy { $0.contexts[deviceID] == nil }, "Queued re-enable revived a retired connection")
    try require(coordinator.pairedPeer(deviceID)?.enabled == true, "Final queued enabled preference not persisted")
    try wait("queued disable invalidated pending transfer") { transfer(fixture, peer: receiver, id: id)?.phase.isTerminal == true }
    try require(transfer(fixture, peer: receiver, id: id)?.reason == "revoked", "Queued disable did not invalidate original transfer authority")
    print("PASS queued disable/re-enable atomically retires peer generations")
}

func testEOFWithHeldClipboardAndDiskWork() throws {
    let fixture = try Fixture(); defer { fixture.close() }
    let (sender, receiver) = try fixture.pair(initiatorHasSmallerUUID: true)
    let (id, _, destination) = try fixture.offer(sender: sender, name: "eof-held-worker.bin", bytes: 401)
    let source = fixture.coordinators[sender], sink = fixture.coordinators[receiver]
    let context = sink.testState()!.contexts[source.localDeviceID]!
    fixture.hooks[receiver].holdRemoteText = { [observations = fixture.observations] release in
        observations.withLock { $0.heldText = release }
    }
    fixture.workers[receiver].isSuspended = true
    let offer = transfer(fixture, peer: receiver, id: id)!
    sink.acceptFileTransfer(id: id, directory: destination, revision: offer.revision, engineEpoch: offer.engineEpoch)
    try wait("production acceptance worker held before authorization callback") { fixture.workers[receiver].operationCount > 0 }
    // The clipboard frame traverses actual production TLS/codec/inbox. A
    // compile-only hook marks that decoded read as EOF to deterministically
    // exercise the stream-completion callback before either worker is released.
    fixture.hooks[receiver].endControlAfterNextClipboard = true
    source.sendAcceptedLocalText("must not reach clipboard")
    do {
        try wait("production receive EOF branch with clipboard inbox held", timeout: 5) {
            sink.testState()?.connections.contains { $0.receivedEOF && $0.retired && $0.inboxHeld } == true &&
            fixture.observations.withLock { $0.heldText != nil }
        }
    } catch {
        fputs("EOF state: \(String(describing: sink.testState())); held=\(fixture.observations.withLock { $0.heldText != nil })\n", stderr)
        fputs("EOF diagnostics: \(fixture.observations.withLock { $0.diagnostics })\n", stderr)
        throw error
    }
    let state = sink.testState()!
    try require(state.contexts[source.localDeviceID] == nil, "EOF left file authority usable while clipboard callback was held")
    try require(state.generations[source.localDeviceID] == context.peerGeneration &+ 1,
                "EOF did not immediately retire peer file generation")
    fixture.workers[receiver].isSuspended = false
    fixture.hooks[receiver].holdRemoteText = nil
    fixture.observations.withLock { $0.heldText }?()
    try wait("held acceptance invalidated after real EOF") { transfer(fixture, peer: receiver, id: id)?.phase.isTerminal == true }
    pump(0.2)
    try require(fixture.delegates[receiver].text.isEmpty, "Delayed clipboard publication survived EOF lifetime cancellation")
    try require(transfer(fixture, peer: receiver, id: id)?.phase != .saved, "Held disk work published after control EOF")
    try require((try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)).isEmpty,
                "Control EOF permitted stale disk callback to write the final destination")
    print("PASS production EOF callback immediately retires authority with clipboard publication and acceptance disk work held")
}

func testOriginalIncomingDeadline() throws {
    let fixture = try Fixture(); defer { fixture.close() }
    let server = fixture.coordinators[1], clock = fixture.clocks[1]
    fixture.hooks[1].beforeIncomingAdoption = { clock.advance(14) }
    let before = clock.now()
    let connection = try unwrap(fixture.coordinators[0].testOpenSilentTLS(to: server.testState()!.port!), "silent TLS probe")
    defer { connection.cancel() }
    try wait("actual incoming TLS routed to production pre-HELLO peer") {
        server.testState()?.connections.contains { $0.incomingPreHello } == true
    }
    let candidate = server.testState()!.connections.first { $0.incomingPreHello }!
    try require(candidate.establishmentStartedAt >= before && candidate.establishmentStartedAt < before + 3,
                "Incoming PeerConnection restarted the deadline after TLS routing")
    clock.advance(2)
    server.testReconcileAfterWake()
    try wait("expired incoming candidate removed after native cancellation", timeout: 5) {
        // The native cancelled state must reach finish even after cancel has
        // marked the peer closing, releasing its incoming candidate slot.
        server.testState()?.connections.contains { $0.id == candidate.id } == false
    }
    try require(server.testState()?.connections.isEmpty == true && server.testState()?.incomingTLSCount == 0,
                "Expired incoming candidate retained a production connection or TLS slot")
    try require(fixture.observations.withLock { $0.diagnostics.contains("connection_ended") },
                "Native cancellation acknowledgement did not finish incoming peer cleanup")
    try require(fixture.observations.withLock { $0.diagnostics.contains("connection_establishment_timed_out_after_wake") },
                "Incoming candidate did not expire using original establishment start")
    print("PASS actual incoming TLS deadline retains original start and native cancellation releases its candidate slot")
}

do {
    try testPairingAndFiles(smallerInitiator: true)
    try testPairingAndFiles(smallerInitiator: false)
    try testQueuedAuthorization()
    try testEOFWithHeldClipboardAndDiskWork()
    try testOriginalIncomingDeadline()
    print("Floatcut V3 production coordinator integration/regression tests passed")
} catch {
    fputs("FAIL production coordinator: \(error)\n", stderr)
    exit(1)
}
