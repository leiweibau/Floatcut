import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

do {
    let fixtures = "docs/Protocol/fixtures/v3"
    let vectorData = try Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/pairing-vectors.json"))
    let vector = (try JSONSerialization.jsonObject(with: vectorData) as! [[String: Any]])[0]
    let initiatorID = vector["initiator_device_id"] as! String
    let acceptorID = vector["acceptor_device_id"] as! String
    let initiatorPin = vector["initiator_certificate_sha256"] as! String
    let acceptorPin = vector["acceptor_certificate_sha256"] as! String
    let initiatorNonce = try FloatcutSyncProtocol.dataFromHex(vector["initiator_nonce_hex"] as! String)
    let acceptorNonce = try FloatcutSyncProtocol.dataFromHex(vector["acceptor_nonce_hex"] as! String)
    let binding = try FloatcutSyncProtocol.controlBinding(
        dialerDeviceID: initiatorID, dialerCertificateSHA256: initiatorPin,
        dialerNonce: try FloatcutSyncProtocol.dataFromHex(vector["initiator_hello_nonce_hex"] as! String),
        listenerDeviceID: acceptorID, listenerCertificateSHA256: acceptorPin,
        listenerNonce: try FloatcutSyncProtocol.dataFromHex(vector["acceptor_hello_nonce_hex"] as! String))
    expect(binding == vector["control_binding_sha256"] as! String, "V3 control binding vector")
    let requestID = vector["request_id"] as! String
    let initiatorCommitment = try FloatcutSyncProtocol.pairingCommitment(
        role: "initiator", requestID: requestID, controlBindingSHA256: binding,
        initiatorDeviceID: initiatorID, initiatorCertificateSHA256: initiatorPin,
        acceptorDeviceID: acceptorID, acceptorCertificateSHA256: acceptorPin, nonce: initiatorNonce)
    let acceptorCommitment = try FloatcutSyncProtocol.pairingCommitment(
        role: "acceptor", requestID: requestID, controlBindingSHA256: binding,
        initiatorDeviceID: initiatorID, initiatorCertificateSHA256: initiatorPin,
        acceptorDeviceID: acceptorID, acceptorCertificateSHA256: acceptorPin, nonce: acceptorNonce)
    expect(initiatorCommitment == vector["initiator_commitment_sha256"] as! String, "initiator commitment vector")
    expect(acceptorCommitment == vector["acceptor_commitment_sha256"] as! String, "acceptor commitment vector")
    let transcript = try FloatcutSyncProtocol.pairingTranscript(
        requestID: requestID, controlBindingSHA256: binding,
        initiatorDeviceID: initiatorID, initiatorCertificateSHA256: initiatorPin, initiatorNonce: initiatorNonce,
        acceptorDeviceID: acceptorID, acceptorCertificateSHA256: acceptorPin, acceptorNonce: acceptorNonce,
        initiatorCommitmentSHA256: initiatorCommitment, acceptorCommitmentSHA256: acceptorCommitment)
    expect(transcript.inputLength == 289, "pairing input length")
    expect(transcript.sha256 == vector["transcript_sha256"] as! String, "pairing transcript hash")
    expect(transcript.comparisonCode == vector["comparison_code"] as! String, "pairing comparison code")
    for object in vector["messages"] as! [[String: Any]] { _ = try FloatcutSyncWireMessage(object: object) }

    expect(FloatcutSyncProtocol.maximumPeers == 32 && FloatcutSyncProtocol.version == 3, "V3 limits")
    var supersetHello = (vector["messages"] as! [[String: Any]])[0]
    supersetHello["capabilities"] = FloatcutSyncProtocol.capabilities + ["future.optional"]
    _ = try FloatcutSyncWireMessage(object: supersetHello)
    supersetHello["capabilities"] = FloatcutSyncProtocol.baseCapabilities
    _ = try FloatcutSyncWireMessage(object: supersetHello)

    let fileFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/file-transfer.json"))) as! [String: Any]
    for object in (fileFixture["messages"] as! [[String: Any]]) + (fileFixture["data_messages"] as! [[String: Any]]) {
        _ = try FloatcutSyncWireMessage(object: object)
    }
    let offer = (fileFixture["messages"] as! [[String: Any]])[0]
    var malformedOffer = offer
    malformedOffer.removeValue(forKey: "file_name")
    let malformedPayload = try JSONSerialization.data(withJSONObject: malformedOffer)
    let admittedEnvelope = try FloatcutSyncCodec.decodePayload(malformedPayload, deferFileOfferValidation: true)
    expect(admittedEnvelope.type == "FILE_OFFER", "offer structural validation can follow Trusted admission")
    do { try admittedEnvelope.validateFileOfferStructure(); expect(false, "Trusted offer validates required structure") }
    catch FloatcutSyncProtocolError.invalidField("file_name") { }
    let offerDigest = try FloatcutSyncProtocol.fileOfferDigest(
        transferID: offer["transfer_id"] as! String, controlBindingSHA256: binding,
        senderDeviceID: initiatorID, receiverDeviceID: acceptorID, byteSize: 3,
        contentSHA256: offer["content_sha256"] as! String, fileName: "report.txt")
    expect(offerDigest == fileFixture["offer_sha256"] as! String, "file offer digest vector")
    let invalidSchema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/invalid/schema-messages.json"))) as! [[String: Any]]
    for fixture in invalidSchema {
        let name = fixture["name"] as! String
        let object = fixture["message"] as! [String: Any]
        if name.hasPrefix("filename-") || name == "size-above-8-gib" || name == "file-open-on-control" {
            // Semantic FILE_OFFER errors and channel classification belong to
            // admission, rather than a generic structural parser error.
            _ = try FloatcutSyncWireMessage(object: object)
        } else {
            do { _ = try FloatcutSyncWireMessage(object: object); expect(false, "\(name) schema rejection") }
            catch { }
        }
    }
    let invalidSemantics = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/invalid/semantic-messages.json"))) as! [[String: Any]]
    for fixture in invalidSemantics {
        let object = fixture["message"] as! [String: Any]
        if fixture["check"] as! String == "filename" {
            _ = try FloatcutSyncWireMessage(object: object)
            expect(!FloatcutSyncProtocol.isPortableFileName(object["file_name"] as! String), "invalid filename semantic vector")
        }
    }
    expect(FloatcutSyncProtocol.portableFileName("../cafe\u{301}:a?. ") == ".._café_a_", "portable basename normalization")
    expect(FloatcutSyncProtocol.portableFileName("..") == "file", "empty portable basename fallback")
    let truncatedName = FloatcutSyncProtocol.portableFileName(String(repeating: "🙂", count: 60))
    expect(truncatedName.utf8.count == 180 && FloatcutSyncProtocol.isPortableFileName(truncatedName), "scalar-aligned UTF8 basename limit")

    var eightDeep: Any = "leaf"
    for _ in 0..<7 { eightDeep = [eightDeep] }
    let depthEightMessage = FloatcutSyncWireMessage(type: "PING", fields: ["sent_at_ms": 1, "extension": eightDeep])
    let depthEight = try FloatcutSyncCodec.encode(depthEightMessage)
    _ = try FloatcutSyncCodec.decodePayload(Data(depthEight.dropFirst(4)))
    let pairOfSurrogates = Data("{\"v\":3,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1,\"extension\":\"\\uD83D\\uDE42\"}".utf8)
    _ = try FloatcutSyncCodec.decodePayload(pairOfSurrogates)

    let boot = "11223344-5566-4788-99aa-bbccddeeff00"
    let requestDeadline = FloatcutSyncBootDeadline.starting(durationMS: 120_000, nowTickMS: 1_000, bootGeneration: boot)!
    var tick: UInt64 = 1_000
    func exchange(_ localIsInitiator: Bool, nonce: Data) throws -> FloatcutSyncPairingV3 {
        try FloatcutSyncPairingV3(requestID: requestID, localIsInitiator: localIsInitiator,
            originalControlBindingSHA256: binding, initiatorDeviceID: initiatorID, initiatorCertificateSHA256: initiatorPin,
            acceptorDeviceID: acceptorID, acceptorCertificateSHA256: acceptorPin, deadline: requestDeadline,
            localNonce: nonce, nowTickMS: { tick }, bootGeneration: { boot })
    }
    let initiator = try exchange(true, nonce: initiatorNonce)
    let acceptor = try exchange(false, nonce: acceptorNonce)
    let request = try initiator.requestMessage()
    let challenge = try acceptor.acceptRequest(initiatorCommitment: request.string("initiator_commitment_sha256"))
    let initiatorReveal = try initiator.receiveChallenge(challenge)
    expect(initiator.transcript == nil && acceptor.transcript == nil, "no code before verified reveals")
    let acceptorReveal = try acceptor.receiveReveal(initiatorReveal)!
    _ = try initiator.receiveReveal(acceptorReveal)
    expect(initiator.transcript == transcript && acceptor.transcript == transcript, "commit/reveal peers agree")
    do { _ = try acceptor.receiveReveal(initiatorReveal); expect(false, "fresh-ID repeat reveal rejected") } catch FloatcutSyncProtocolError.invalidState { }
    let prematureComplete = FloatcutSyncWireMessage(type: "PAIR_COMPLETE", fields: ["request_id": requestID, "transcript_sha256": transcript.sha256])
    do { try initiator.receiveConfirmation(prematureComplete); expect(false, "COMPLETE cannot manufacture confirmations") } catch FloatcutSyncProtocolError.invalidState { }
    let initiatorConfirm = try initiator.confirmLocal()
    try acceptor.receiveConfirmation(initiatorConfirm)
    expect(!acceptor.localConfirmed && acceptor.remoteConfirmed, "remote confirmation preserves local user flag")
    let acceptorConfirm = try acceptor.confirmLocal()
    try initiator.receiveConfirmation(acceptorConfirm)
    try initiator.markCompleted(nowTickMS: 2_000, bootGeneration: boot)
    let firstCompletionDeadline = initiator.deadline
    try initiator.markCompleted(nowTickMS: 3_000, bootGeneration: boot)
    expect(initiator.deadline == firstCompletionDeadline, "completion retention never renewed")
    let badAcceptor = try exchange(false, nonce: acceptorNonce)
    _ = try badAcceptor.acceptRequest(initiatorCommitment: String(repeating: "0", count: 64))
    do { _ = try badAcceptor.receiveReveal(initiatorReveal); expect(false, "commitment mismatch rejected") } catch FloatcutSyncProtocolError.commitmentMismatch { }
    expect(badAcceptor.phase == .invalidated && badAcceptor.transcript == nil, "mismatch invalidates the exchange")
    tick = 121_000
    do { _ = try acceptor.confirmLocal(); expect(false, "pairing decision invalid at exact deadline") } catch FloatcutSyncProtocolError.invalidState { }

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
        ) == "pairing_busy",
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

    let fixture = try Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/clipboard-update.json"))
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

    let duplicate = Data("{\"v\":3,\"v\":3,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1}".utf8)
    do {
        _ = try FloatcutSyncCodec.decodePayload(duplicate)
        expect(false, "duplicate key rejected")
    } catch FloatcutSyncProtocolError.duplicateJSONKey("v") {
        expect(true, "duplicate key rejected")
    }

    let exponent = Data("{\"v\":3,\"type\":\"PING\",\"message_id\":\"01234567-89ab-4cde-8f01-23456789abcd\",\"sent_at_ms\":1e3}".utf8)
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

    for fixtureName in ["invalid-utf8", "duplicate-key", "nesting-depth-9", "lone-high-surrogate", "lone-low-surrogate", "lone-surrogate-key", "integer-as-float", "integer-as-exponent", "nonfinite-number"] {
        var invalid = FloatcutSyncFrameDecoder()
        do {
            let frame = try Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/invalid/\(fixtureName).frame"))
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

    let imageFixtureData = try Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/image-transfer.json"))
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
            let frame = try Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/invalid/\(fixtureName).frame"))
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
