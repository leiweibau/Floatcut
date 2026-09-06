import Foundation
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
if CommandLine.arguments[1] == "emit" {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 900,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var random: UInt32 = 42
    for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        random = random &* 1_664_525 &+ 1_013_904_223
        bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: random >> 24)
    }
    var frames = Data()
    let text = "Floatcut SRC interoperability: ä🙂\n\"quoted\""
    let textBytes = Data(text.utf8)
    frames.append(try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType, "utf8_size": textBytes.count,
        "content_sha256": FloatcutSyncProtocol.sha256Hex(textBytes), "hop_count": 0, "content": text,
    ])))
    for (format, mime, name): (NSBitmapImageRep.FileType, String, String) in [(.png, "image/png", "png"), (.jpeg, "image/jpeg", "jpeg")] {
        let data = bitmap.representation(using: format, properties: [.compressionFactor: 0.85])!
        try data.write(to: directory.appendingPathComponent("source.\(name)"))
        let clipID = FloatcutSyncProtocol.uuidV4()
        let count = (data.count + FloatcutSyncProtocol.imageChunkBytes - 1) / FloatcutSyncProtocol.imageChunkBytes
        frames.append(try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_BEGIN", fields: [
            "clip_id": clipID, "source_device_id": FloatcutSyncProtocol.uuidV4(), "created_at_ms": 1,
            "content_type": mime, "byte_size": data.count, "content_sha256": FloatcutSyncProtocol.sha256Hex(data),
            "chunk_size": FloatcutSyncProtocol.imageChunkBytes, "chunk_count": count, "hop_count": 0,
        ])))
        for index in 0..<count {
            let start = index * FloatcutSyncProtocol.imageChunkBytes
            let chunk = data.subdata(in: start..<min(start + FloatcutSyncProtocol.imageChunkBytes, data.count))
            frames.append(try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_CHUNK", fields: [
                "clip_id": clipID, "chunk_index": index, "data_size": chunk.count,
                "data_sha256": FloatcutSyncProtocol.sha256Hex(chunk), "data": FloatcutSyncProtocol.base64URL(chunk),
            ])))
        }
        frames.append(try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_COMMIT", fields: ["clip_id": clipID])))
        print("Floatcut emitted \(mime): \(data.count) bytes, \(count) chunks")
    }
    try frames.write(to: directory.appendingPathComponent("floatcut.frames"))
} else {
    let bytes = try Data(contentsOf: directory.appendingPathComponent("src.frames"))
    var decoder = FloatcutSyncFrameDecoder()
    var file: FloatcutIncomingImageFile?
    var images = 0
    var texts = 0
    for offset in stride(from: 0, to: bytes.count, by: 7919) {
        for message in try decoder.append(bytes.subdata(in: offset..<min(bytes.count, offset + 7919))) {
            switch message.type {
            case "CLIPBOARD_UPDATE": texts += 1
            case "CLIPBOARD_IMAGE_BEGIN":
                precondition(file == nil)
                file = try FloatcutIncomingImageFile(message: message, directory: directory.appendingPathComponent("incoming"))
            case "CLIPBOARD_IMAGE_CHUNK": try file!.append(message)
            case "CLIPBOARD_IMAGE_COMMIT":
                let data = try file!.finish()
                let suffix = file!.contentType == "image/png" ? "png" : "jpeg"
                let expected = try Data(contentsOf: directory.appendingPathComponent("source.\(suffix)"))
                precondition(data == expected, "SRC round trip changed image bytes")
                file!.cleanup()
                file = nil
                images += 1
            default: fatalError("unexpected fixture message")
            }
        }
    }
    try decoder.finish()
    precondition(images == 2 && texts == 1 && file == nil)
    print("SRC → Floatcut: text and multi-chunk PNG/JPEG validated, byte-identical; no TLS/discovery test")
}
