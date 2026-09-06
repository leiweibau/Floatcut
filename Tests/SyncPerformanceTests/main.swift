import Foundation

// Synthetic CPU benchmark; no network, clipboard, preferences or identity access.
func measure(_ name: String, iterations: Int = 30, _ work: () throws -> Void) rethrows {
    for _ in 0..<3 { try work() }
    var values = [Double]()
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    print("\(name) samples_ms: \(values.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    values.sort()
    print(String(format: "%@: n=%d min=%.3f median=%.3f p95=%.3f max=%.3f ms",
                 name, iterations, values[0], values[iterations / 2],
                 values[Int(Double(iterations - 1) * 0.95)], values[iterations - 1]))
}

let chunk = Data((0..<FloatcutSyncProtocol.imageChunkBytes).map { UInt8($0 % 251) })
let message = FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_CHUNK", fields: [
    "clip_id": FloatcutSyncProtocol.uuidV4(), "chunk_index": 0,
    "data_size": chunk.count, "data_sha256": FloatcutSyncProtocol.sha256Hex(chunk),
    "data": FloatcutSyncProtocol.base64URL(chunk),
])
try measure("encode 44 chunks (one ~2 MiB image)") {
    for _ in 0..<44 { _ = try FloatcutSyncCodec.encode(message) }
}
let frame = try FloatcutSyncCodec.encode(message)
try measure("decode 44 chunks") {
    var decoder = FloatcutSyncFrameDecoder()
    for _ in 0..<44 { _ = try decoder.append(frame) }
}
let content = String(repeating: "Floatcut ä\n", count: 16_000)
let text = Data(content.utf8)
let textMessage = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
    "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
    "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType,
    "utf8_size": text.count, "content_sha256": FloatcutSyncProtocol.sha256Hex(text),
    "hop_count": 0, "content": content,
])
try measure("encode escaped text \(text.count) bytes") { _ = try FloatcutSyncCodec.encode(textMessage) }
