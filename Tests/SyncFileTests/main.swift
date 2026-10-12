import CryptoKit
import Darwin
import Foundation
import Network

var checks = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fatalError(message) }
}
func expectFailure(_ reason: String? = nil, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure \(reason ?? "")") }
    catch { if let reason { check((error as? FloatcutFileFailure)?.wireReason == reason, "Wrong reason \(error), expected \(reason)") } }
}
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: "/private/tmp/FloatcutFile-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func digest(_ bytes: Data) -> String { FloatcutSyncProtocol.sha256Hex(bytes) }
func manifest(_ bytes: Data, id: String = FloatcutSyncProtocol.uuidV4()) -> FloatcutFileManifest {
    FloatcutFileManifest(transferID: id, senderDeviceID: "00000000-0000-4000-8000-000000000001",
                        receiverDeviceID: "00000000-0000-4000-8000-000000000002", fileName: "report.txt",
                        byteSize: Int64(bytes.count), contentSHA256: digest(bytes), offerSHA256: String(repeating: "a", count: 64))
}
func parse(_ bytes: Data, size: Int64, fragment: Int) throws -> (Int64, String) {
    var parser = FloatcutFileBinaryParser(byteSize: size)
    var cursor = 0; var total: Int64 = 0; var hasher = SHA256(); var endHash = ""
    while cursor < bytes.count, !parser.ended {
        let count = min(fragment, parser.receiveBudget, bytes.count - cursor)
        let input = bytes.subdata(in: cursor..<cursor + count); cursor += count
        if let record = try parser.consume(input) {
            switch record {
            case .data(let offset, let payload):
                check(offset == total, "Sequential offset")
                total += Int64(payload.count); hasher.update(data: payload)
            case .end(let size, let hash): check(size == total, "END size"); endHash = hash
            }
        }
        check(parser.receiveBudget <= 65_536, "Bounded receive request")
    }
    try parser.finishEOF()
    check(endHash == hasher.finalize().map { String(format: "%02x", $0) }.joined(), "END total hash")
    return (total, endHash)
}

// Contract boundaries, fragmented TLS reads, exact chunks and mandatory END.
for size in [0, 1, 262_143, 262_144, 262_145, 524_288, 1_048_577] {
    let bytes = Data((0..<size).map { UInt8($0 % 251) })
    var stream = Data(); var offset = 0
    while offset < bytes.count {
        let count = min(262_144, bytes.count - offset)
        stream.append(FloatcutFileBinaryParser.dataRecord(offset: Int64(offset), bytes: bytes.subdata(in: offset..<offset + count)))
        offset += count
    }
    stream.append(try FloatcutFileBinaryParser.endRecord(size: Int64(size), hash: digest(bytes)))
    for fragment in [1, 127, 65_536] {
        let parsed = try parse(stream, size: Int64(size), fragment: fragment)
        check(parsed.0 == Int64(size), "Boundary \(size), fragment \(fragment)")
    }
}
// Common invalid fixtures: wrong offsets/length, empty DATA, truncation and missing END.
for leaf in ["wrong-offset.bin", "wrong-end-size.bin", "zero-data-bytes.bin", "wrong-end-length.bin", "unknown-opcode.bin", "oversized-data-record.bin", "truncated-data-header.bin", "truncated-data-payload.bin", "missing-end.bin", "short-middle-chunk.bin", "excess-data.bin"] {
    let bytes = try Data(contentsOf: fixtures.appendingPathComponent("invalid/\(leaf)"))
    expectFailure { _ = try parse(bytes, size: leaf == "short-middle-chunk.bin" ? 262_145 : 3, fragment: 17) }
}
// A valid END terminates immediately; trailing bytes are not interpreted.
var empty = try FloatcutFileBinaryParser.endRecord(size: 0, hash: digest(Data()))
empty.append(Data([0xff, 0xff]))
check(try parse(empty, size: 0, fragment: 65_536).0 == 0, "END closes parser immediately")

// Native APFS publication must never replace a racing destination.
let destination = root.appendingPathComponent("destination")
let snapshots = root.appendingPathComponent("snapshots")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let source = root.appendingPathComponent("source.txt")
let original = Data("immutable snapshot".utf8)
try original.write(to: source)
let snapshot = try FloatcutFileStorage.snapshot(source: source, in: snapshots)
try Data("source changed".utf8).write(to: source)
check(try FloatcutFileStorage.readSnapshot(snapshot, offset: 0, count: original.count) == original, "Source modification cannot change bytes")
check(snapshot.contentSHA256 == digest(original), "Hash describes snapshot")
snapshot.remove(); snapshot.remove()
let symlink = root.appendingPathComponent("symlink")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
expectFailure { _ = try FloatcutFileStorage.snapshot(source: symlink, in: snapshots) }
expectFailure("invalid_source") { _ = try FloatcutFileStorage.snapshot(source: destination, in: snapshots) }
let fifo = root.appendingPathComponent("fifo")
check(mkfifo(fifo.path, 0o600) == 0, "Create FIFO")
expectFailure("invalid_source") { _ = try FloatcutFileStorage.snapshot(source: fifo, in: snapshots) }

let bytes = Data("abc".utf8)
let offered = manifest(bytes)
let storage = try FloatcutFileStorage(directory: destination, finalLeaf: "\(offered.transferID)-report.txt", requiredBytes: 3)
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(storage.stagingLeaf).appendingPathComponent("payload").path), "No payload before valid OPEN")
try storage.createPayload(); try storage.write(bytes, offset: 0)
let identity = try storage.verifyAndFlush(manifest: offered)
try storage.publish()
let final = destination.appendingPathComponent(storage.finalLeaf)
check(try Data(contentsOf: final) == bytes, "Native exclusive publication bytes")
var finalInfo = stat(); check(lstat(final.path, &finalInfo) == 0, "Published stat")
check(FloatcutFileStorage.identity(finalInfo) == identity, "Publication retains stable identity")
storage.cleanup(); check(FileManager.default.fileExists(atPath: final.path), "Late cleanup cannot remove published file")
expectFailure("destination_exists") { _ = try FloatcutFileStorage(directory: destination, finalLeaf: storage.finalLeaf, requiredBytes: 3) }
let racing = try FloatcutFileStorage(directory: destination, finalLeaf: "collision.txt", requiredBytes: 3)
try racing.createPayload(); try racing.write(bytes, offset: 0); _ = try racing.verifyAndFlush(manifest: offered)
let collision = destination.appendingPathComponent("collision.txt")
try Data("foreign".utf8).write(to: collision)
expectFailure("destination_exists") { try racing.publish() }
racing.cleanup(); check(try Data(contentsOf: collision) == Data("foreign".utf8), "Race-created file unchanged")
let wrongHashStorage = try FloatcutFileStorage(directory: destination, finalLeaf: "wrong-hash.txt", requiredBytes: 3)
try wrongHashStorage.createPayload(); try wrongHashStorage.write(bytes, offset: 0)
let wrongHashManifest = FloatcutFileManifest(transferID: offered.transferID, senderDeviceID: offered.senderDeviceID,
    receiverDeviceID: offered.receiverDeviceID, fileName: offered.fileName, byteSize: 3,
    contentSHA256: String(repeating: "0", count: 64), offerSHA256: offered.offerSHA256)
expectFailure("hash_mismatch") { _ = try wrongHashStorage.verifyAndFlush(manifest: wrongHashManifest) }
wrongHashStorage.cleanup()
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("wrong-hash.txt").path), "Hash mismatch never publishes")
let directoryLink = root.appendingPathComponent("directory-link")
try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: destination)
expectFailure("unsupported_destination") { _ = try FloatcutFileStorage(directory: directoryLink, finalLeaf: "safe", requiredBytes: 0) }

// Journal recovery uses device/inode+size+hash, and saved receipts survive deletion.
let metadata = root.appendingPathComponent("metadata")
var journal: FloatcutFileTransferJournal? = FloatcutFileTransferJournal(directory: metadata, wallClock: { 1000 })
_ = try journal!.loadAndReconcile(nowMilliseconds: 1000)
var record = FloatcutFileTransferJournal.Record(manifest: offered, direction: .incoming, peerID: offered.senderDeviceID,
    peerPin: String(repeating: "b", count: 64), trustGeneration: 1, peerName: "Other Mac", state: "prepared", reason: nil,
    destinationDirectory: destination.path, destinationIdentity: storage.directoryIdentity, stagingLeaf: storage.stagingLeaf,
    finalLeaf: storage.finalLeaf, fileIdentity: identity, terminalAtMilliseconds: nil)
try journal!.put(record); journal = nil
journal = FloatcutFileTransferJournal(directory: metadata, wallClock: { 1000 })
let recovered = try journal!.loadAndReconcile(nowMilliseconds: 2000)
check(recovered.count == 1 && recovered[0].state == "saved", "Prepared published identity recovers saved")
try FileManager.default.removeItem(at: final); journal = nil
journal = FloatcutFileTransferJournal(directory: metadata, wallClock: { 1000 })
check(try journal!.loadAndReconcile(nowMilliseconds: 3000)[0].state == "saved", "Saved historical receipt survives deletion")
expectFailure("invalid_state") { record.state = "prepared"; try journal!.put(record) }
journal = nil

// A replacing epoch cannot recover a journal while an older grant still owns it.
let ownershipDirectory = root.appendingPathComponent("ownership")
var owner: FloatcutFileTransferJournal? = FloatcutFileTransferJournal(directory: ownershipDirectory)
_ = try owner!.loadAndReconcile(nowMilliseconds: 1000)
let waitingOwner = FloatcutFileTransferJournal(directory: ownershipDirectory)
let acquired = DispatchSemaphore(value: 0)
DispatchQueue.global().async { _ = try! waitingOwner.loadAndReconcile(nowMilliseconds: 2000); acquired.signal() }
check(acquired.wait(timeout: .now() + 0.1) == .timedOut, "Replacement waits for journal ownership")
owner = nil
check(acquired.wait(timeout: .now() + 2) == .success, "Replacement acquires journal after old owner releases")

// Several days of historical receipts cannot disable startup before pruning.
struct TestJournalDocument: Codable { let version: Int; let records: [FloatcutFileTransferJournal.Record] }
let rolloverDirectory = root.appendingPathComponent("rollover")
try FileManager.default.createDirectory(at: rolloverDirectory, withIntermediateDirectories: true)
var historical: [FloatcutFileTransferJournal.Record] = []
for _ in 0..<2050 {
    var expired = record; expired.manifest = manifest(bytes); expired.state = "failed"; expired.reason = "control_lost"; expired.terminalAtMilliseconds = 0
    historical.append(expired)
}
var retained = record; retained.manifest = manifest(bytes); retained.state = "failed"; retained.reason = "io_error"; retained.terminalAtMilliseconds = 86_400_000
historical.append(retained)
try JSONEncoder().encode(TestJournalDocument(version: 1, records: historical)).write(to: rolloverDirectory.appendingPathComponent("journal.json"))
var rolloverNow: Int64 = 86_400_000
let rolloverJournal = FloatcutFileTransferJournal(directory: rolloverDirectory, wallClock: { rolloverNow })
let rolloverLoaded = try rolloverJournal.loadAndReconcile(nowMilliseconds: rolloverNow)
check(rolloverLoaded.count == 1, "Expired historical rows pruned before 2048 retained capacity")
rolloverNow += 86_400_000
var newReceipt = retained; newReceipt.manifest = manifest(bytes); newReceipt.terminalAtMilliseconds = rolloverNow
try rolloverJournal.put(newReceipt)
var protectedPrepared = record; protectedPrepared.manifest = manifest(bytes); protectedPrepared.state = "prepared"; protectedPrepared.terminalAtMilliseconds = nil
try rolloverJournal.put(protectedPrepared)
let compacted = try JSONDecoder().decode(TestJournalDocument.self, from: Data(contentsOf: rolloverDirectory.appendingPathComponent("journal.json")))
check(compacted.records.count == 2 && compacted.records.contains { $0.state == "prepared" }, "Mutation durably prunes expired receipts while preserving prepared grants")

let abandonedDirectory = root.appendingPathComponent("abandoned")
var abandonedJournal: FloatcutFileTransferJournal? = FloatcutFileTransferJournal(directory: abandonedDirectory, wallClock: { 1000 })
_ = try abandonedJournal!.loadAndReconcile(nowMilliseconds: 1000)
let abandonedStorage = try FloatcutFileStorage(directory: destination, finalLeaf: "abandoned.txt", requiredBytes: 3)
try abandonedStorage.createPayload(); try abandonedStorage.write(bytes, offset: 0)
var abandonedRecord = record; abandonedRecord.manifest = manifest(bytes); abandonedRecord.state = "accepted"
abandonedRecord.terminalAtMilliseconds = nil; abandonedRecord.fileIdentity = nil; abandonedRecord.finalLeaf = abandonedStorage.finalLeaf
abandonedRecord.stagingLeaf = abandonedStorage.stagingLeaf; abandonedRecord.destinationIdentity = abandonedStorage.directoryIdentity
try abandonedJournal!.put(abandonedRecord); abandonedJournal = nil
abandonedJournal = FloatcutFileTransferJournal(directory: abandonedDirectory, wallClock: { 2000 })
let abandonedRecovered = try abandonedJournal!.loadAndReconcile(nowMilliseconds: 2000)
check(abandonedRecovered[0].state == "failed" && abandonedRecovered[0].reason == "control_lost", "Accepted restart never resumes bytes")
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(abandonedStorage.stagingLeaf).appendingPathComponent("payload").path), "Accepted restart deletes private partial bytes")
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(abandonedStorage.finalLeaf).path), "Accepted restart cannot publish")
abandonedJournal = nil
let collisionMetadata = root.appendingPathComponent("collision-metadata")
journal = FloatcutFileTransferJournal(directory: collisionMetadata, wallClock: { 1000 })
_ = try journal!.loadAndReconcile(nowMilliseconds: 1000)
let collisionOffer = manifest(bytes)
record.manifest = collisionOffer; record.state = "prepared"; record.finalLeaf = "identical-foreign.txt"; record.terminalAtMilliseconds = nil
try bytes.write(to: destination.appendingPathComponent(record.finalLeaf!))
try journal!.put(record); journal = nil
journal = FloatcutFileTransferJournal(directory: collisionMetadata, wallClock: { 1000 })
let collisionRecovered = try journal!.loadAndReconcile(nowMilliseconds: 2000)
check(collisionRecovered[0].state == "failed" && collisionRecovered[0].reason == "io_error", "Identical bytes with foreign inode never saved")
check(try Data(contentsOf: destination.appendingPathComponent(record.finalLeaf!)) == bytes, "Recovery leaves foreign file")
journal = nil

final class TestClock: FloatcutSyncElapsedClock { var value: TimeInterval = 100; func now() -> TimeInterval { value } }
let clock = TestClock()
let queue = DispatchQueue(label: "file-tests.authority")
let senderID = "00000000-0000-4000-8000-000000000001"
let receiverID = "00000000-0000-4000-8000-000000000002"
let binding = String(repeating: "a", count: 64)
let peer = FloatcutFilePeerContext(deviceID: senderID, name: "Sender", certificateSHA256: String(repeating: "b", count: 64),
    trustGeneration: 1, peerGeneration: 1, controlConnectionID: UUID(), controlBindingSHA256: binding, engineEpoch: 1, mutualFileCapability: true)
var activePeer: FloatcutFilePeerContext? = peer
var sent: [FloatcutSyncWireMessage] = []
var views: [FloatcutFileTransferSnapshot] = []
let diskWorkers = OperationQueue()
let engine = FloatcutFileTransferEngine(queue: queue, localDeviceID: receiverID, localCertificateSHA256: String(repeating: "c", count: 64), epoch: 1,
    metadataDirectory: root.appendingPathComponent("engine"), clock: clock, lookupPeer: { _ in activePeer },
    sendControl: { _, message in sent.append(message) }, connectFile: { _ in throw FloatcutFileFailure.reason("io_error") },
    onSnapshots: { views = $0 }, diskWorkers: diskWorkers)
let startupDeadline = Date().addingTimeInterval(5)
while !queue.sync(execute: { engine.isReady }) && Date() < startupDeadline { Thread.sleep(forTimeInterval: 0.01) }
check(queue.sync { engine.isReady }, "Startup reconciliation completed")
func offer(size: Int64 = 3, name: String = "report.txt", target: String = receiverID, id: String = FloatcutSyncProtocol.uuidV4(), context: FloatcutFilePeerContext = peer) throws -> FloatcutSyncWireMessage {
    let hash = digest(bytes)
    let digest = try FloatcutSyncProtocol.fileOfferDigest(transferID: id, controlBindingSHA256: binding,
        senderDeviceID: senderID, receiverDeviceID: target, byteSize: size, contentSHA256: hash, fileName: name)
    return FloatcutSyncWireMessage(type: "FILE_OFFER", fields: ["transfer_id": id, "target_device_id": target,
        "file_name": name, "byte_size": size, "content_sha256": hash, "offer_sha256": digest])
}
let wrongTarget = try offer(target: senderID)
try queue.sync { try engine.handleControl(wrongTarget, peer: peer) }
check(queue.sync { sent.last?.fields["reason"] as? String == "invalid_offer" && views.isEmpty }, "Wrong target rejected before UI")
let tooLarge = try offer(size: 8_589_934_593)
try queue.sync { try engine.handleControl(tooLarge, peer: peer) }
check(queue.sync { sent.last?.fields["reason"] as? String == "too_large" }, "8 GiB plus one rejected semantically")
let validOffer = try offer()
try queue.sync { try engine.handleControl(validOffer, peer: peer) }
let id = try validOffer.string("transfer_id")
check(queue.sync { views.first?.phase == .offered && !sent.contains { $0.type == "FILE_ACCEPT" } }, "Consent required, no ACCEPT")
try queue.sync { try engine.handleControl(validOffer, peer: peer) }
check(queue.sync { sent.last?.fields["reason"] as? String == "duplicate_transfer" && views.count == 1 }, "Duplicate cannot create second prompt")
let wrongRevision = queue.sync { views.first!.revision + 100 }
engine.accept(id: id, directory: destination, revision: wrongRevision)
queue.sync {}
check(queue.sync { !sent.contains { $0.type == "FILE_ACCEPT" } }, "Stale dialog revision cannot accept")
queue.sync { clock.value = 160; engine.reconcileDeadlines() }
check(queue.sync { views.first?.phase == .rejected && sent.last?.fields["reason"] as? String == "timeout" }, "60 second equality expires offer")
let cancelledOffer = try offer()
try queue.sync { try engine.handleControl(cancelledOffer, peer: peer) }
let cancelledID = try cancelledOffer.string("transfer_id")
let cancelledRevision = queue.sync { views.first { $0.id == cancelledID }!.revision }
engine.cancel(id: cancelledID, revision: cancelledRevision); queue.sync {}
check(queue.sync { views.first { $0.id == cancelledID }?.phase == .cancelled }, "Receiver explicit cancel closes consent")
engine.accept(id: cancelledID, directory: destination, revision: cancelledRevision); queue.sync {}
check(queue.sync { !sent.contains { $0.type == "FILE_ACCEPT" } }, "Late consent cannot revive cancelled offer")
let busyA = try offer()
let busyB = try offer()
try queue.sync { try engine.handleControl(busyA, peer: peer); try engine.handleControl(busyB, peer: peer) }
check(queue.sync { sent.last?.fields["reason"] as? String == "busy" }, "One incoming slot per peer")
diskWorkers.isSuspended = true
let blockedID = try busyA.string("transfer_id")
let blockedRevision = queue.sync { views.first { $0.id == blockedID }!.revision }
engine.accept(id: blockedID, directory: destination, revision: blockedRevision)
queue.sync {}
check(queue.sync { !sent.contains { $0.type == "FILE_ACCEPT" } }, "Blocked disk worker cannot send acceptance")
queue.sync { activePeer = nil; engine.reconcileDeadlines() }
check(queue.sync { views.first { $0.id == (try? busyA.string("transfer_id")) }?.phase == .failed }, "Control invalidation closes work")
diskWorkers.isSuspended = false
diskWorkers.waitUntilAllOperationsAreFinished(); queue.sync {}
check(queue.sync { !sent.contains { $0.type == "FILE_ACCEPT" } }, "Delayed worker cannot revive invalidated control")
queue.sync { engine.shutdown() }

let hugeSnapshot = FloatcutFileTransferSnapshot(id: "id", direction: .outgoing, phase: .receiving, peerDeviceID: "p", peerName: "p", fileName: "f",
    byteSize: Int64.max, receivedBytes: Int64.max - 1, revision: 1, engineEpoch: 1, localDestination: nil, reason: nil)
check(hugeSnapshot.percentage == 99, "Percentage arithmetic cannot overflow")
print("Floatcut V3 file tests passed (\(checks) assertions; APFS publication and journal recovery native)")

// Controlled receipt failure: no terminal RESULT or quota release is fabricated.
let faultQueue = DispatchQueue(label: "file-tests.faults")
let faultClock = TestClock()
let faultWorkers = OperationQueue()
let faultLock = NSLock()
var rejectTerminalWrites = true
var holdOutboundWrites = false
let outboundEntered = DispatchSemaphore(value: 0)
let outboundContinue = DispatchSemaphore(value: 0)
var faultMessages: [FloatcutSyncWireMessage] = []
var faultViews: [FloatcutFileTransferSnapshot] = []
var faultWallTime: Int64 = 1000
let faultDirectory = root.appendingPathComponent("faults")
let faultEngine = FloatcutFileTransferEngine(queue: faultQueue, localDeviceID: receiverID,
    localCertificateSHA256: String(repeating: "c", count: 64), epoch: 1, metadataDirectory: faultDirectory, clock: faultClock,
    lookupPeer: { _ in peer }, sendControl: { _, message in faultMessages.append(message) },
    connectFile: { _ in throw FloatcutFileFailure.reason("io_error") }, onSnapshots: { faultViews = $0 },
    diskWorkers: faultWorkers, wallClock: { faultWallTime }, beforeJournalWrite: { record in
        faultLock.lock(); let reject = rejectTerminalWrites && record.state == "cancelled"
        let hold = holdOutboundWrites && record.state == "outbound"; faultLock.unlock()
        if reject { throw FloatcutFileFailure.reason("io_error") }
        if hold { outboundEntered.signal(); _ = outboundContinue.wait(timeout: .now() + 5) }
    })
func waitFault(_ condition: @escaping () -> Bool, _ label: String) {
    let deadline = Date().addingTimeInterval(5)
    while !faultQueue.sync(execute: condition), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    check(faultQueue.sync(execute: condition), label)
}
waitFault({ faultEngine.isReady }, "Fault engine recovered")
let faultOffer = try offer()
let faultID = try faultOffer.string("transfer_id")
try faultQueue.sync { try faultEngine.handleControl(faultOffer, peer: peer) }
let offeredRevision = faultQueue.sync { faultViews.first { $0.id == faultID }!.revision }
faultEngine.accept(id: faultID, directory: destination, revision: offeredRevision)
waitFault({ faultMessages.contains { $0.type == "FILE_ACCEPT" && (try? $0.string("transfer_id")) == faultID } }, "Accepted journal durable before token")
// Simulate progress overtaking the main-thread Cancel snapshot: an older
// revision still refers to the exact same transfer and active authority.
faultEngine.cancel(id: faultID, revision: offeredRevision)
waitFault({ faultViews.first { $0.id == faultID }?.phase == .unconfirmed }, "Failed receipt write remains uncertain")
check(faultQueue.sync { !faultMessages.contains { $0.type == "FILE_RESULT" && ($0.fields["status"] as? String) == "cancelled" } }, "No fabricated cancelled receipt")
let statusRequest = FloatcutSyncWireMessage(type: "FILE_STATUS_REQUEST", fields: ["transfer_id": faultID, "offer_sha256": try faultOffer.string("offer_sha256")])
try faultQueue.sync { try faultEngine.handleControl(statusRequest, peer: peer) }
check(faultQueue.sync { faultMessages.last?.fields["status"] as? String == "pending" }, "Uncertain receipt status stays pending")
try faultQueue.sync { try faultEngine.handleControl(offer(), peer: peer) }
check(faultQueue.sync { faultMessages.last?.fields["reason"] as? String == "busy" }, "Unpersisted terminal still owns quota")
faultLock.lock(); rejectTerminalWrites = false; faultLock.unlock()
waitFault({ faultViews.first { $0.id == faultID }?.phase == .cancelled }, "Exact cancelled outcome is retried durably")
check(faultQueue.sync { faultMessages.contains { $0.type == "FILE_RESULT" && ($0.fields["status"] as? String) == "cancelled" && ($0.fields["reason"] as? String) == "user_cancelled" } }, "Durable cancellation result confirms exact reason")
faultQueue.sync { faultWallTime += 86_400_000 }
try faultQueue.sync { try faultEngine.handleControl(statusRequest, peer: peer) }
check(faultQueue.sync { faultMessages.last?.fields["status"] as? String == "unknown" && faultViews.contains { $0.id == faultID && $0.phase == .cancelled } }, "24 hour receipt expiry wins over terminal window history")

// A cancelled preparation must compensate a metadata write finishing later.
faultLock.lock(); holdOutboundWrites = true; faultLock.unlock()
let outboundID = faultEngine.sendFile(url: source, peer: peer)
check(outboundEntered.wait(timeout: .now() + 5) == .success, "Outbound metadata write held")
let preparingRevision = faultQueue.sync { faultViews.first { $0.id == outboundID }!.revision }
faultEngine.cancel(id: outboundID, revision: preparingRevision); faultQueue.sync {}
check(faultQueue.sync { faultViews.first { $0.id == outboundID }?.phase == .cancelled }, "Cancellation retires preparing transfer")
check(faultQueue.sync { !faultMessages.contains { ($0.fields["transfer_id"] as? String) == outboundID } }, "Unsent offer cannot emit unsolicited CANCEL")
outboundContinue.signal(); faultLock.lock(); holdOutboundWrites = false; faultLock.unlock()
let compensationDeadline = Date().addingTimeInterval(5)
var compensated = false
while !compensated, Date() < compensationDeadline {
    faultWorkers.waitUntilAllOperationsAreFinished(); faultQueue.sync {}
    let document = try JSONDecoder().decode(TestJournalDocument.self, from: Data(contentsOf: faultDirectory.appendingPathComponent("journal.json")))
    compensated = !document.records.contains { $0.manifest.transferID == outboundID }
    if !compensated { Thread.sleep(forTimeInterval: 0.01) }
}
check(compensated, "Late outbound put compensated durably")

// Valid ACCEPT with a temporary routing failure must leave control usable.
let routingID = faultEngine.sendFile(url: source, peer: peer)
waitFault({ faultViews.first { $0.id == routingID }?.phase == .offered }, "Routing test offer queued")
let routingOffer = faultQueue.sync { faultMessages.last { $0.type == "FILE_OFFER" && ($0.fields["transfer_id"] as? String) == routingID }! }
let acceptance = FloatcutSyncWireMessage(type: "FILE_ACCEPT", fields: ["transfer_id": routingID,
    "offer_sha256": try routingOffer.string("offer_sha256"), "accept_token": FloatcutSyncProtocol.base64URL(Data(repeating: 1, count: 32)), "expires_in_ms": 15000])
try faultQueue.sync { try faultEngine.handleControl(acceptance, peer: peer) }
check(faultQueue.sync { faultViews.first { $0.id == routingID }?.phase == .failed && !faultMessages.contains { $0.type == "ERROR" } }, "Local connection failure does not escape as a control error")
try faultQueue.sync { try faultEngine.handleControl(statusRequest, peer: peer) }
check(faultQueue.sync { faultMessages.last?.type == "FILE_RESULT" }, "Healthy control continues to answer queries")
faultQueue.sync { faultEngine.shutdown() }
waitFault({ faultEngine.canRetire }, "Shutdown relinquishes journal only after all stale work drains")
print("Floatcut V3 controlled file fault tests passed (\(checks) total assertions)")
