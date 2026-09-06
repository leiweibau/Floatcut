import Foundation
import AppKit

func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError(label) }
}
func rejects(_ label: String, _ work: () throws -> Void) {
    do { try work(); fatalError(label) } catch { }
}

// Deterministic queue tests: held completions model a busy UI/disk worker.
let inbox = FloatcutSyncOrderedInbox()
var order: [Int] = []
var releaseFirst: (() -> Void)?
inbox.enqueue(bytes: FloatcutSyncProtocol.maximumFrameBytes) { done in
    order.append(1)
    releaseFirst = done
}
inbox.enqueue(bytes: FloatcutSyncProtocol.maximumFrameBytes) { done in order.append(2); done() }
expect(order == [1], "second import must wait for actual completion")
expect(!inbox.canReceive, "read backpressure at byte budget")
let otherPeer = FloatcutSyncOrderedInbox()
otherPeer.enqueue(bytes: 10) { done in order.append(3); done() }
expect(order == [1, 3], "another peer must progress while first import waits")
releaseFirst?()
expect(order == [1, 3, 2] && inbox.isEmpty && inbox.pendingBytes == 0, "FIFO completion and accounting")
releaseFirst?()
expect(inbox.pendingBytes == 0, "duplicate completion must have no effect")
inbox.enqueue(bytes: 1) { done in releaseFirst = done }
inbox.enqueue(bytes: 1) { _ in fatalError("discarded work ran") }
inbox.discard()
inbox.enqueue(bytes: 1) { done in done() }
releaseFirst?()
expect(inbox.isEmpty && inbox.pendingBytes == 0, "late old-generation completion must be ignored")
let token = FloatcutSyncWorkToken()
DispatchQueue.global().sync { token.cancel() }
expect(!token.isActive, "cancellation crosses queues")
let preparation = FloatcutSyncImagePreparation()
let firstTicket = preparation.reserve()!
expect(preparation.reserve() == nil, "one preparation per peer bounds retained images")
preparation.cancel()
let secondTicket = preparation.reserve()!
expect(!preparation.consume(firstTicket), "off/on cannot revive a prepared image")
expect(preparation.consume(secondTicket), "new preparation after off/on")
expect(!preparation.consume(secondTicket), "preparation is consumed only once")

let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
    URL(fileURLWithPath: "docs/Protocol/fixtures/v2/image-transfer.json"))) as! [String: Any]
let objects = fixture["messages"] as! [[String: Any]]
let begin = try FloatcutSyncWireMessage(object: objects[0])
let chunk = try FloatcutSyncWireMessage(object: objects[2])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floatcut-work-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

try FloatcutSyncImageWork.queue.sync {
    let file = try FloatcutIncomingImageFile(message: begin, directory: directory)
    try file.append(chunk)
    let bytes = try file.finish()
    expect(FloatcutSyncProtocol.sha256Hex(bytes) == fixture["decoded_image_sha256"] as! String, "fixture import hash")
    let paths = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    expect(paths.count == 1 && paths[0].hasSuffix(".validated"), "file survives validation until UI completes")
    file.cleanup()
    expect(try! FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "successful cleanup")
    expect(FloatcutSyncProtocol.sha256Hex(bytes) == fixture["decoded_image_sha256"] as! String, "mapped data remains readable")

    let incomplete = try FloatcutIncomingImageFile(message: begin, directory: directory)
    rejects("incomplete image accepted") { _ = try incomplete.finish() }
    incomplete.cleanup()

    let cancelled = try FloatcutIncomingImageFile(message: begin, directory: directory)
    cancelled.token.cancel()
    rejects("cancelled transfer wrote data") { try cancelled.append(chunk) }
    rejects("cancelled transfer committed") { _ = try cancelled.finish() }
    cancelled.cleanup()

    let closed = try FloatcutIncomingImageFile(message: begin, directory: directory)
    closed.cleanup()
    rejects("closed file write accepted") { try closed.append(chunk) }

    var wrongIndex = objects[2]
    wrongIndex["chunk_index"] = 1
    let outOfOrder = try FloatcutIncomingImageFile(message: begin, directory: directory)
    rejects("out-of-order chunk accepted") { try outOfOrder.append(FloatcutSyncWireMessage(object: wrongIndex)) }
    try outOfOrder.append(chunk)
    rejects("duplicate chunk written") { try outOfOrder.append(chunk) }
    outOfOrder.cleanup()

    var badHash = objects[0]
    badHash["content_sha256"] = String(repeating: "0", count: 64)
    let mismatch = try FloatcutIncomingImageFile(message: FloatcutSyncWireMessage(object: badHash), directory: directory)
    try mismatch.append(chunk)
    rejects("wrong final hash accepted") { _ = try mismatch.finish() }
    mismatch.cleanup()
    expect(try! FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "failure paths clean up files")
}

// Pump only the test process's run loop; no app, clipboard or user preferences.
let service = FloatcutThumbnailService()
let png = chunk.validatedImageChunk!
var thumbnails = [NSImage]()
var callbackCount = 0
for _ in 0..<3 {
    service.request(data: png, identifier: "fixture", size: 88, scale: 2) { image in
        expect(Thread.isMainThread, "thumbnail completion must run on main thread")
        expect(image != nil, "valid PNG thumbnail missing")
        thumbnails.append(image!)
        callbackCount += 1
    }
}
service.request(data: Data([1, 2, 3]), identifier: "invalid", size: 88, scale: 2) { image in
    expect(image == nil, "invalid image produced a thumbnail")
    callbackCount += 1
}
let deadline = Date().addingTimeInterval(10)
while callbackCount < 4 && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
expect(callbackCount == 4, "thumbnail work timed out")
expect(thumbnails[0] === thumbnails[1] && thumbnails[1] === thumbnails[2], "in-flight requests must share result")
expect(service.cachedImage(identifier: "fixture", size: 88, scale: 2) === thumbnails[0], "warm cache")
expect(service.cachedImage(identifier: "fixture", size: 88, scale: 1) == nil, "scale-specific cache key")
expect(service.cachedImage(identifier: "fixture", size: 40, scale: 2) == nil, "size-specific cache key")
print("Floatcut ordered work, image-file lifecycle and thumbnail tests passed")
