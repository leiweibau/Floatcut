import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

do {
    let vectorData = try Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/v2/pairing-vectors.json"))
    let vectors = try JSONSerialization.jsonObject(with: vectorData) as! [[String: Any]]
    let vector = vectors[0]
    let transcript = try FloatcutSyncProtocol.pairingTranscript(
        initiatorDeviceID: vector["initiator_device_id"] as! String,
        initiatorCertificateSHA256: vector["initiator_certificate_sha256"] as! String,
        initiatorNonce: try FloatcutSyncProtocol.dataFromHex(vector["initiator_nonce"] as! String),
        acceptorDeviceID: vector["acceptor_device_id"] as! String,
        acceptorCertificateSHA256: vector["acceptor_certificate_sha256"] as! String,
        acceptorNonce: try FloatcutSyncProtocol.dataFromHex(vector["acceptor_nonce"] as! String)
    )
    expect(transcript.inputLength == vector["input_length"] as! Int, "pairing input length")
    expect(transcript.sha256 == vector["transcript_sha256"] as! String, "pairing transcript hash")
    expect(transcript.comparisonCode == vector["comparison_code"] as! String, "pairing comparison code")

    expect(
        FloatcutSyncPairingPolicy.advertisementValue(allowsNewPairings: true, pairedPeerCount: 0) == "1",
        "pairing is advertised by default"
    )
    expect(
        FloatcutSyncPairingPolicy.advertisementValue(allowsNewPairings: false, pairedPeerCount: 0) == "0",
        "disabled pairing is not advertised"
    )
    expect(
        FloatcutSyncPairingPolicy.advertisementValue(
            allowsNewPairings: true,
            pairedPeerCount: FloatcutSyncProtocol.maximumPeers
        ) == "0",
        "full peer store is not advertised for pairing"
    )
    expect(
        FloatcutSyncPairingPolicy.rejectionReason(
            allowsNewPairings: false,
            pairedPeerCount: 0,
            concurrentPairingCount: 0
        ) == "pairing_disabled",
        "disabled incoming pairing uses the normative reason"
    )
    expect(
        FloatcutSyncPairingPolicy.rejectionReason(
            allowsNewPairings: true,
            pairedPeerCount: FloatcutSyncProtocol.maximumPeers,
            concurrentPairingCount: 0
        ) == "peer_limit",
        "peer limit uses the normative reason"
    )
    expect(
        FloatcutSyncPairingPolicy.rejectionReason(
            allowsNewPairings: true,
            pairedPeerCount: 0,
            concurrentPairingCount: FloatcutSyncPairingPolicy.maximumConcurrentPairings
        ) == "invalid_request",
        "concurrent pairing limit rejects the request"
    )
    expect(
        FloatcutSyncPairingPolicy.rejectionReason(
            allowsNewPairings: true,
            pairedPeerCount: 0,
            concurrentPairingCount: 0
        ) == nil,
        "available pairing request is accepted"
    )

    let fixture = try Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/v2/clipboard-update.json"))
    let message = try FloatcutSyncCodec.decodePayload(fixture)
    expect(message.type == "CLIPBOARD_UPDATE", "clipboard fixture type")
    let encoded = try FloatcutSyncCodec.encode(message)
    expect(encoded.count > 4, "encoded framed message")
    var fragmented = FloatcutSyncFrameDecoder()
    let prefixMessages = try fragmented.append(encoded.prefix(2))
    expect(prefixMessages.isEmpty, "fragmented frame prefix")
    let decoded = try fragmented.append(encoded.dropFirst(2))
    expect(decoded.count == 1 && decoded[0].type == "CLIPBOARD_UPDATE", "fragmented frame completion")
    var bytewise = FloatcutSyncFrameDecoder()
    var bytewiseMessages: [FloatcutSyncWireMessage] = []
    for byte in encoded {
        bytewiseMessages.append(contentsOf: try bytewise.append(Data([byte])))
    }
    expect(bytewiseMessages.count == 1, "frame accepted one byte at a time")

    let duplicate = Data("{\"v\":2,\"v\":2,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1}".utf8)
    do {
        _ = try FloatcutSyncCodec.decodePayload(duplicate)
        expect(false, "duplicate key rejected")
    } catch FloatcutSyncProtocolError.duplicateJSONKey("v") {
        expect(true, "duplicate key rejected")
    }

    let exponent = Data("{\"v\":2,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1e3}".utf8)
    do {
        _ = try FloatcutSyncCodec.decodePayload(exponent)
        expect(false, "exponent JSON number rejected")
    } catch FloatcutSyncProtocolError.nonIntegerJSONNumber {
        expect(true, "exponent JSON number rejected")
    }

    var oversized = FloatcutSyncFrameDecoder()
    do {
        _ = try oversized.append(Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/invalid/oversized-length.frame")))
        expect(false, "oversized length rejected")
    } catch FloatcutSyncProtocolError.invalidFrameLength(1_048_577) {
        expect(true, "oversized length rejected")
    }

    var zero = FloatcutSyncFrameDecoder()
    do {
        _ = try zero.append(Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/invalid/zero-length.frame")))
        expect(false, "zero length rejected")
    } catch FloatcutSyncProtocolError.invalidFrameLength(0) {
        expect(true, "zero length rejected")
    }

    for fixtureName in ["invalid-utf8", "duplicate-key", "nesting-depth-9", "invalid-hash"] {
        var invalid = FloatcutSyncFrameDecoder()
        do {
            let frame = try Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/invalid/\(fixtureName).frame"))
            _ = try invalid.append(frame)
            expect(false, "\(fixtureName) fixture rejected")
        } catch {
            expect(true, "\(fixtureName) fixture rejected")
        }
    }

    let v1Envelope = Data("{\"v\":1,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1}".utf8)
    do {
        _ = try FloatcutSyncCodec.decodePayload(v1Envelope)
        expect(false, "v1 envelope rejected")
    } catch FloatcutSyncProtocolError.incompatibleVersion(1) {
        expect(true, "v1 envelope rejected")
    }

    let imageFixtureData = try Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/v2/image-transfer.json"))
    let imageFixture = try JSONSerialization.jsonObject(with: imageFixtureData) as! [String: Any]
    let imageObjects = imageFixture["messages"] as! [[String: Any]]
    let imageMessages = try imageObjects.map(FloatcutSyncWireMessage.init(object:))
    expect(imageMessages.map(\.type) == ["CLIPBOARD_IMAGE_BEGIN", "CLIPBOARD_ACK", "CLIPBOARD_IMAGE_CHUNK", "CLIPBOARD_IMAGE_COMMIT", "CLIPBOARD_ACK"], "image fixture sequence")
    let fixtureChunk = try FloatcutSyncProtocol.decodeBase64URL(try imageMessages[2].string("data"))
    expect(imageMessages[2].validatedImageChunk == fixtureChunk, "validated chunk is reusable without decoding again")
    let chunkFrame = try FloatcutSyncCodec.encode(imageMessages[2])
    let decodedChunk = try FloatcutSyncCodec.decodePayload(Data(chunkFrame.dropFirst(4)))
    expect(decodedChunk.validatedImageChunk == fixtureChunk, "wire decoder retains validated chunk")
    expect(decodedChunk.payloadByteCount == chunkFrame.count - 4, "inbox byte accounting")

    for value: Any in [1.5, 1e100] {
        do {
            _ = try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "PING", fields: ["sent_at_ms": 1, "extension": value]))
            expect(false, "local encoder must reject fractional/exponential extension numbers")
        } catch FloatcutSyncProtocolError.nonIntegerJSONNumber { }
    }
    var nested: Any = "leaf"
    for _ in 0..<FloatcutSyncProtocol.maximumJSONDepth { nested = [nested] }
    do {
        _ = try FloatcutSyncCodec.encode(FloatcutSyncWireMessage(type: "PING", fields: ["sent_at_ms": 1, "extension": nested]))
        expect(false, "local encoder depth limit")
    } catch FloatcutSyncProtocolError.nestingTooDeep { }
    expect(FloatcutSyncProtocol.sha256Hex(fixtureChunk) == imageFixture["decoded_image_sha256"] as! String, "image fixture decoded hash")

    let maximumImageBegin = FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_BEGIN", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": "image/png", "byte_size": FloatcutSyncProtocol.maximumImageBytes,
        "content_sha256": String(repeating: "a", count: 64), "chunk_size": FloatcutSyncProtocol.imageChunkBytes,
        "chunk_count": FloatcutSyncProtocol.maximumImageChunks, "hop_count": 0,
    ])
    _ = try FloatcutSyncCodec.encode(maximumImageBegin)

    var badChunk = imageObjects[2]
    badChunk["data_sha256"] = String(repeating: "0", count: 64)
    do {
        _ = try FloatcutSyncWireMessage(object: badChunk)
        expect(false, "bad image chunk hash rejected")
    } catch FloatcutSyncProtocolError.hashMismatch {
        expect(true, "bad image chunk hash rejected")
    }

    var badBegin = imageObjects[0]
    badBegin["chunk_count"] = 2
    do {
        _ = try FloatcutSyncWireMessage(object: badBegin)
        expect(false, "inconsistent image chunk count rejected")
    } catch FloatcutSyncProtocolError.invalidField("chunk_count") {
        expect(true, "inconsistent image chunk count rejected")
    }
    for fixtureName in ["truncated-prefix", "truncated-payload"] {
        var truncated = FloatcutSyncFrameDecoder()
        do {
            let frame = try Data(contentsOf: URL(fileURLWithPath: "docs/Protocol/fixtures/invalid/\(fixtureName).frame"))
            _ = try truncated.append(frame)
            try truncated.finish()
            expect(false, "\(fixtureName) fixture rejected at EOF")
        } catch FloatcutSyncProtocolError.incompleteFrame {
            expect(true, "\(fixtureName) fixture rejected at EOF")
        }
    }

    let unicodeContent = "Ä🙂e\u{301}\r\nnext"
    let unicodeData = Data(unicodeContent.utf8)
    let unicode = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(),
        "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1,
        "content_type": FloatcutSyncProtocol.contentType,
        "utf8_size": unicodeData.count,
        "content_sha256": FloatcutSyncProtocol.sha256Hex(unicodeData),
        "hop_count": 0,
        "content": unicodeContent,
        "future_optional_field": "ignored",
    ])
    var unicodeDecoder = FloatcutSyncFrameDecoder()
    let unicodeRoundTrip = try unicodeDecoder.appendingSingle(try FloatcutSyncCodec.encode(unicode))
    let decodedUnicodeContent = try unicodeRoundTrip.string("content")
    expect(decodedUnicodeContent == unicodeContent, "Unicode and CRLF preserved")

    let maximumContent = String(repeating: "x", count: FloatcutSyncProtocol.maximumClipboardBytes)
    let maximumData = Data(maximumContent.utf8)
    let maximumMessage = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType,
        "utf8_size": maximumData.count, "content_sha256": FloatcutSyncProtocol.sha256Hex(maximumData),
        "hop_count": 0, "content": maximumContent,
    ])
    let maximumFrame = try FloatcutSyncCodec.encode(maximumMessage)
    var coalesced = FloatcutSyncFrameDecoder()
    let twoMaximumFrames = try coalesced.append(maximumFrame + maximumFrame)
    expect(twoMaximumFrames.count == 2, "multiple coalesced maximum-content frames")

    let tooLargeContent = maximumContent + "x"
    let tooLargeData = Data(tooLargeContent.utf8)
    let tooLargeMessage = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType,
        "utf8_size": tooLargeData.count, "content_sha256": FloatcutSyncProtocol.sha256Hex(tooLargeData),
        "hop_count": 0, "content": tooLargeContent,
    ])
    do {
        _ = try FloatcutSyncCodec.encode(tooLargeMessage)
        expect(false, "clipboard payload above 512 KiB rejected")
    } catch FloatcutSyncProtocolError.payloadTooLarge {
        expect(true, "clipboard payload above 512 KiB rejected")
    }

    let maximumEscapedContent = String(repeating: "\n", count: FloatcutSyncProtocol.maximumClipboardBytes)
    let maximumEscapedData = Data(maximumEscapedContent.utf8)
    let maximumEscapedMessage = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType,
        "utf8_size": maximumEscapedData.count, "content_sha256": FloatcutSyncProtocol.sha256Hex(maximumEscapedData),
        "hop_count": 0, "content": maximumEscapedContent,
    ])
    do {
        _ = try FloatcutSyncCodec.encode(maximumEscapedMessage)
        expect(false, "JSON-escaped frame above 1 MiB rejected")
    } catch FloatcutSyncProtocolError.invalidFrameLength {
        expect(true, "JSON-escaped frame above 1 MiB rejected")
    }

    let emptyMessage = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: [
        "clip_id": FloatcutSyncProtocol.uuidV4(), "source_device_id": FloatcutSyncProtocol.uuidV4(),
        "created_at_ms": 1, "content_type": FloatcutSyncProtocol.contentType,
        "utf8_size": 0, "content_sha256": FloatcutSyncProtocol.sha256Hex(Data()),
        "hop_count": 0, "content": "",
    ])
    do {
        _ = try FloatcutSyncCodec.encode(emptyMessage)
        expect(false, "empty clipboard payload rejected")
    } catch FloatcutSyncProtocolError.invalidField("content") {
        expect(true, "empty clipboard payload rejected")
    }
} catch {
    failures += 1
    FileHandle.standardError.write(Data("FAIL: unexpected error: \(error)\n".utf8))
}

if failures > 0 { exit(1) }
print("Floatcut sync protocol tests passed")

private extension FloatcutSyncFrameDecoder {
    mutating func appendingSingle(_ data: Data) throws -> FloatcutSyncWireMessage {
        let messages = try append(data)
        guard messages.count == 1 else { throw FloatcutSyncProtocolError.incompleteFrame }
        return messages[0]
    }
}
