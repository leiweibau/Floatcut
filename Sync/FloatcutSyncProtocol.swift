import CryptoKit
import Foundation
import Security

enum FloatcutSyncProtocol {
    static let version = 2
    static let serviceType = "_floatcutsync._tcp"
    static let capabilities = ["clip.image.jpeg", "clip.image.png", "clip.text.utf8"]
    static let capability = "clip.text.utf8"
    static let maximumFrameBytes = 1_048_576
    static let maximumClipboardBytes = 524_288
    static let maximumJSONDepth = 8
    static let maximumDeviceNameBytes = 64
    static let maximumPeers = 10
    static let contentType = "text/plain;charset=utf-8"
    static let imageContentTypes = ["image/png", "image/jpeg"]
    static let maximumImageBytes = 16_777_216
    static let imageChunkBytes = 49_152
    static let maximumImageChunks = 342
    static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    static let jpegSignature = Data([0xff, 0xd8, 0xff])

    static func uuidV4() -> String {
        UUID().uuidString.lowercased()
    }

    static func isCanonicalUUID(_ value: String, requireV4: Bool = true) -> Bool {
        guard value == value.lowercased(),
              value.count == 36,
              value[value.index(value.startIndex, offsetBy: 8)] == "-",
              value[value.index(value.startIndex, offsetBy: 13)] == "-",
              value[value.index(value.startIndex, offsetBy: 18)] == "-",
              value[value.index(value.startIndex, offsetBy: 23)] == "-",
              UUID(uuidString: value) != nil
        else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if requireV4 {
            guard value[value.index(value.startIndex, offsetBy: 14)] == "4",
                  "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)])
            else { return false }
        }
        return true
    }

    static func truncateDeviceName(_ value: String) -> String {
        truncateUTF8(value, maximumBytes: maximumDeviceNameBytes, fallback: "Floatcut")
    }

    static func isPlatformIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9._-]{1,16}$", options: .regularExpression) != nil
    }

    static func truncateUTF8(_ value: String, maximumBytes: Int, fallback: String) -> String {
        var bytes = 0
        var result = ""
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maximumBytes else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty ? fallback : result
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func secureNonce() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw FloatcutSyncProtocolError.randomFailure(status) }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String, expectedBytes: Int? = nil) throws -> Data {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw FloatcutSyncProtocolError.invalidField("base64url")
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard),
              base64URL(data) == value,
              expectedBytes == nil || data.count == expectedBytes else {
            throw FloatcutSyncProtocolError.invalidField("base64url")
        }
        return data
    }

    static func dataFromHex(_ value: String, expectedBytes: Int? = nil) throws -> Data {
        guard value.count.isMultiple(of: 2),
              value.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else { throw FloatcutSyncProtocolError.invalidField("hex") }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw FloatcutSyncProtocolError.invalidField("hex")
            }
            result.append(byte)
            index = next
        }
        guard expectedBytes == nil || result.count == expectedBytes else {
            throw FloatcutSyncProtocolError.invalidField("hex")
        }
        return result
    }

    static func uuidBytes(_ value: String) throws -> Data {
        guard isCanonicalUUID(value, requireV4: false), let uuid = UUID(uuidString: value) else {
            throw FloatcutSyncProtocolError.invalidField("uuid")
        }
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    static func pairingTranscript(
        initiatorDeviceID: String,
        initiatorCertificateSHA256: String,
        initiatorNonce: Data,
        acceptorDeviceID: String,
        acceptorCertificateSHA256: String,
        acceptorNonce: Data
    ) throws -> FloatcutPairingTranscript {
        guard initiatorNonce.count == 32, acceptorNonce.count == 32 else {
            throw FloatcutSyncProtocolError.invalidField("nonce")
        }
        var input = Data("FLOATCUT-PAIR-V2\0".utf8)
        input.append(try uuidBytes(initiatorDeviceID))
        input.append(try dataFromHex(initiatorCertificateSHA256, expectedBytes: 32))
        input.append(initiatorNonce)
        input.append(try uuidBytes(acceptorDeviceID))
        input.append(try dataFromHex(acceptorCertificateSHA256, expectedBytes: 32))
        input.append(acceptorNonce)
        let digest = Data(SHA256.hash(data: input))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return FloatcutPairingTranscript(
            inputLength: input.count,
            sha256: sha256Hex(input),
            comparisonCode: String(format: "%06u", number)
        )
    }
}

enum FloatcutSyncPairingPolicy {
    static let maximumConcurrentPairings = 3

    static func advertisementValue(allowsNewPairings: Bool, pairedPeerCount: Int) -> String {
        allowsNewPairings && pairedPeerCount < FloatcutSyncProtocol.maximumPeers ? "1" : "0"
    }

    static func rejectionReason(
        allowsNewPairings: Bool,
        pairedPeerCount: Int,
        concurrentPairingCount: Int
    ) -> String? {
        if !allowsNewPairings { return "pairing_disabled" }
        if pairedPeerCount >= FloatcutSyncProtocol.maximumPeers { return "peer_limit" }
        if concurrentPairingCount >= maximumConcurrentPairings { return "invalid_request" }
        return nil
    }
}

struct FloatcutPairingTranscript: Equatable {
    let inputLength: Int
    let sha256: String
    let comparisonCode: String
}

enum FloatcutSyncProtocolError: Error, LocalizedError, Equatable {
    case invalidFrameLength(Int)
    case incompleteFrame
    case invalidUTF8
    case invalidJSON(String)
    case duplicateJSONKey(String)
    case nestingTooDeep
    case nonIntegerJSONNumber
    case invalidEnvelope
    case incompatibleVersion(Int)
    case unknownMessageType(String)
    case invalidField(String)
    case payloadTooLarge
    case hashMismatch
    case invalidState
    case randomFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let length): return "Invalid frame length: \(length)"
        case .incompleteFrame: return "Incomplete frame"
        case .invalidUTF8: return "Invalid UTF-8"
        case .invalidJSON(let detail): return "Invalid JSON: \(detail)"
        case .duplicateJSONKey(let key): return "Duplicate JSON key: \(key)"
        case .nestingTooDeep: return "JSON nesting exceeds eight levels"
        case .nonIntegerJSONNumber: return "JSON numbers must be integers without exponents"
        case .invalidEnvelope: return "Invalid protocol envelope"
        case .incompatibleVersion(let version): return "Unsupported protocol version \(version)"
        case .unknownMessageType(let type): return "Unknown message type \(type)"
        case .invalidField(let field): return "Invalid field \(field)"
        case .payloadTooLarge: return "Clipboard payload too large"
        case .hashMismatch: return "Clipboard content hash mismatch"
        case .invalidState: return "Message is not allowed in this connection state"
        case .randomFailure(let status): return "Secure random generation failed (\(status))"
        }
    }
}

struct FloatcutSyncWireMessage {
    static let knownTypes: Set<String> = [
        "HELLO", "PAIR_REQUEST", "PAIR_CHALLENGE", "PAIR_CONFIRM", "PAIR_STATUS",
        "PAIR_COMPLETE", "PAIR_REJECT", "CLIPBOARD_UPDATE", "CLIPBOARD_ACK",
        "CLIPBOARD_IMAGE_BEGIN", "CLIPBOARD_IMAGE_CHUNK", "CLIPBOARD_IMAGE_COMMIT",
        "CLIPBOARD_IMAGE_ABORT", "PING", "PONG", "UNPAIR", "UNPAIR_ACK", "ERROR",
    ]

    let type: String
    let messageID: String
    let fields: [String: Any]
    // Only populated by validation; callers cannot substitute unverified bytes.
    private(set) var validatedImageChunk: Data?
    let payloadByteCount: Int

    init(type: String, messageID: String = FloatcutSyncProtocol.uuidV4(), fields: [String: Any] = [:]) {
        self.type = type
        self.messageID = messageID
        self.fields = fields
        self.payloadByteCount = 0
    }

    init(object: [String: Any]) throws {
        try self.init(object: object, payloadByteCount: 0)
    }

    init(object: [String: Any], payloadByteCount: Int) throws {
        guard let version = object["v"] as? Int else { throw FloatcutSyncProtocolError.invalidEnvelope }
        guard version == FloatcutSyncProtocol.version else { throw FloatcutSyncProtocolError.incompatibleVersion(version) }
        guard let type = object["type"] as? String,
              let messageID = object["message_id"] as? String,
              FloatcutSyncProtocol.isCanonicalUUID(messageID)
        else { throw FloatcutSyncProtocolError.invalidEnvelope }
        guard Self.knownTypes.contains(type) else { throw FloatcutSyncProtocolError.unknownMessageType(type) }
        self.type = type
        self.messageID = messageID
        self.fields = object
        self.payloadByteCount = payloadByteCount
        try validate()
    }

    var object: [String: Any] {
        var result = fields
        result["v"] = FloatcutSyncProtocol.version
        result["type"] = type
        result["message_id"] = messageID
        return result
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key] as? String else { throw FloatcutSyncProtocolError.invalidField(key) }
        return value
    }

    func integer(_ key: String) throws -> Int64 {
        if let number = object[key] as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw FloatcutSyncProtocolError.invalidField(key)
            }
            return number.int64Value
        }
        if let value = object[key] as? Int64 { return value }
        if let value = object[key] as? Int { return Int64(value) }
        throw FloatcutSyncProtocolError.invalidField(key)
    }

    private mutating func validate() throws {
        switch type {
        case "HELLO":
            guard FloatcutSyncProtocol.isCanonicalUUID(try string("device_id")),
                  try string("device_name").utf8.count <= FloatcutSyncProtocol.maximumDeviceNameBytes,
                  !(try string("device_name")).isEmpty,
                  FloatcutSyncProtocol.isPlatformIdentifier(try string("platform")),
                  let capabilities = object["capabilities"] as? [String],
                  capabilities == FloatcutSyncProtocol.capabilities
            else { throw FloatcutSyncProtocolError.invalidField("HELLO") }
            _ = try FloatcutSyncProtocol.dataFromHex(try string("certificate_sha256"), expectedBytes: 32)
            _ = try FloatcutSyncProtocol.decodeBase64URL(try string("session_nonce"), expectedBytes: 32)
        case "PAIR_REQUEST":
            try validateUUIDField("request_id")
            _ = try FloatcutSyncProtocol.decodeBase64URL(try string("initiator_nonce"), expectedBytes: 32)
        case "PAIR_CHALLENGE":
            try validateUUIDField("request_id")
            _ = try FloatcutSyncProtocol.decodeBase64URL(try string("acceptor_nonce"), expectedBytes: 32)
        case "PAIR_CONFIRM", "PAIR_COMPLETE":
            try validateUUIDField("request_id")
            _ = try FloatcutSyncProtocol.dataFromHex(try string("transcript_sha256"), expectedBytes: 32)
        case "PAIR_STATUS":
            try validateUUIDField("request_id")
            _ = try FloatcutSyncProtocol.dataFromHex(try string("transcript_sha256"), expectedBytes: 32)
            guard ["confirmed", "complete"].contains(try string("state")) else {
                throw FloatcutSyncProtocolError.invalidField("state")
            }
        case "PAIR_REJECT":
            try validateUUIDField("request_id")
            guard ["user_rejected", "timeout", "peer_limit", "pairing_disabled", "already_paired", "invalid_request"].contains(try string("reason")) else {
                throw FloatcutSyncProtocolError.invalidField("reason")
            }
        case "CLIPBOARD_UPDATE":
            try validateClipboardUpdate()
        case "CLIPBOARD_ACK":
            try validateUUIDField("clip_id")
            guard ["ready", "applied", "duplicate", "skipped", "unsupported", "invalid"].contains(try string("status")) else {
                throw FloatcutSyncProtocolError.invalidField("status")
            }
        case "CLIPBOARD_IMAGE_BEGIN":
            try validateImageBegin()
        case "CLIPBOARD_IMAGE_CHUNK":
            validatedImageChunk = try validateImageChunk()
        case "CLIPBOARD_IMAGE_COMMIT":
            try validateUUIDField("clip_id")
        case "CLIPBOARD_IMAGE_ABORT":
            try validateUUIDField("clip_id")
            if object["reason"] != nil,
               !["sender_cancelled", "timeout", "io_error"].contains(try string("reason")) {
                throw FloatcutSyncProtocolError.invalidField("reason")
            }
        case "PING":
            try validateTimestamp("sent_at_ms")
        case "PONG":
            try validateUUIDField("reply_to")
        case "UNPAIR":
            try validateUUIDField("revocation_id")
            try validateTimestamp("revoked_at_ms")
            if object["reason"] != nil, try string("reason") != "user_request" {
                throw FloatcutSyncProtocolError.invalidField("reason")
            }
        case "UNPAIR_ACK":
            try validateUUIDField("revocation_id")
        case "ERROR":
            guard !(try string("code")).isEmpty, !(try string("detail")).isEmpty else {
                throw FloatcutSyncProtocolError.invalidField("ERROR")
            }
            if object["reply_to"] != nil { try validateUUIDField("reply_to") }
        default:
            throw FloatcutSyncProtocolError.unknownMessageType(type)
        }
    }

    private func validateClipboardUpdate() throws {
        try validateUUIDField("clip_id")
        try validateUUIDField("source_device_id")
        try validateTimestamp("created_at_ms")
        guard try string("content_type") == FloatcutSyncProtocol.contentType,
              try integer("hop_count") == 0
        else { throw FloatcutSyncProtocolError.invalidField("CLIPBOARD_UPDATE") }
        let content = try string("content")
        let data = Data(content.utf8)
        guard !data.isEmpty else { throw FloatcutSyncProtocolError.invalidField("content") }
        guard data.count <= FloatcutSyncProtocol.maximumClipboardBytes else { throw FloatcutSyncProtocolError.payloadTooLarge }
        guard try integer("utf8_size") == Int64(data.count) else { throw FloatcutSyncProtocolError.invalidField("utf8_size") }
        _ = try FloatcutSyncProtocol.dataFromHex(try string("content_sha256"), expectedBytes: 32)
        guard FloatcutSyncProtocol.sha256Hex(data) == (try string("content_sha256")) else {
            throw FloatcutSyncProtocolError.hashMismatch
        }
    }

    private func validateImageBegin() throws {
        try validateUUIDField("clip_id")
        try validateUUIDField("source_device_id")
        try validateTimestamp("created_at_ms")
        let contentType = try string("content_type")
        guard FloatcutSyncProtocol.imageContentTypes.contains(contentType),
              try integer("hop_count") == 0,
              try integer("chunk_size") == Int64(FloatcutSyncProtocol.imageChunkBytes)
        else { throw FloatcutSyncProtocolError.invalidField("CLIPBOARD_IMAGE_BEGIN") }
        let byteSize = try integer("byte_size")
        let minimum = contentType == "image/png" ? 8 : 3
        guard byteSize >= Int64(minimum), byteSize <= Int64(FloatcutSyncProtocol.maximumImageBytes) else {
            throw FloatcutSyncProtocolError.payloadTooLarge
        }
        let expectedChunks = (byteSize + Int64(FloatcutSyncProtocol.imageChunkBytes) - 1) / Int64(FloatcutSyncProtocol.imageChunkBytes)
        guard try integer("chunk_count") == expectedChunks,
              expectedChunks >= 1, expectedChunks <= Int64(FloatcutSyncProtocol.maximumImageChunks)
        else { throw FloatcutSyncProtocolError.invalidField("chunk_count") }
        _ = try FloatcutSyncProtocol.dataFromHex(try string("content_sha256"), expectedBytes: 32)
    }

    private func validateImageChunk() throws -> Data {
        try validateUUIDField("clip_id")
        let index = try integer("chunk_index")
        let size = try integer("data_size")
        guard index >= 0, index < Int64(FloatcutSyncProtocol.maximumImageChunks),
              size >= 1, size <= Int64(FloatcutSyncProtocol.imageChunkBytes)
        else { throw FloatcutSyncProtocolError.invalidField("CLIPBOARD_IMAGE_CHUNK") }
        let decoded = try FloatcutSyncProtocol.decodeBase64URL(try string("data"))
        guard decoded.count == Int(size) else { throw FloatcutSyncProtocolError.invalidField("data_size") }
        _ = try FloatcutSyncProtocol.dataFromHex(try string("data_sha256"), expectedBytes: 32)
        guard FloatcutSyncProtocol.sha256Hex(decoded) == (try string("data_sha256")) else {
            throw FloatcutSyncProtocolError.hashMismatch
        }
        return decoded
    }

    private func validateUUIDField(_ key: String) throws {
        guard FloatcutSyncProtocol.isCanonicalUUID(try string(key)) else {
            throw FloatcutSyncProtocolError.invalidField(key)
        }
    }

    private func validateTimestamp(_ key: String) throws {
        let value = try integer(key)
        guard value >= 0, value < 9_007_199_254_740_992 else {
            throw FloatcutSyncProtocolError.invalidField(key)
        }
    }
}

enum FloatcutSyncCodec {
    static func encode(_ message: FloatcutSyncWireMessage) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message.object) else {
            throw FloatcutSyncProtocolError.invalidJSON("not an object")
        }
        // Locally built dictionaries have unique keys and serialization produces
        // valid UTF-8/escapes. Validate values without reparsing large strings.
        try validateLocalJSON(message.object, depth: 1)
        _ = try FloatcutSyncWireMessage(object: message.object)
        let payload = try JSONSerialization.data(withJSONObject: message.object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard !payload.isEmpty, payload.count <= FloatcutSyncProtocol.maximumFrameBytes else {
            throw FloatcutSyncProtocolError.invalidFrameLength(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    static func decodePayload(_ payload: Data) throws -> FloatcutSyncWireMessage {
        guard !payload.isEmpty, payload.count <= FloatcutSyncProtocol.maximumFrameBytes else {
            throw FloatcutSyncProtocolError.invalidFrameLength(payload.count)
        }
        guard String(data: payload, encoding: .utf8) != nil else { throw FloatcutSyncProtocolError.invalidUTF8 }
        var validator = StrictJSONValidator(data: payload)
        try validator.validate()
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw FloatcutSyncProtocolError.invalidJSON(error.localizedDescription)
        }
        guard let object = raw as? [String: Any] else { throw FloatcutSyncProtocolError.invalidEnvelope }
        return try FloatcutSyncWireMessage(object: object, payloadByteCount: payload.count)
    }

    private static func validateLocalJSON(_ value: Any, depth: Int) throws {
        guard depth <= FloatcutSyncProtocol.maximumJSONDepth else {
            throw FloatcutSyncProtocolError.nestingTooDeep
        }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values { try validateLocalJSON(child, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for child in array { try validateLocalJSON(child, depth: depth + 1) }
        } else if let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() {
            // Preserve the strict wire rule even for unknown extension fields:
            // Foundation's actual spelling must not contain a fraction/exponent.
            var validator = StrictJSONValidator(data: try JSONSerialization.data(withJSONObject: [number]))
            try validator.validate()
        }
    }
}

struct FloatcutSyncFrameDecoder {
    private(set) var buffer = Data()

    mutating func append(_ incoming: Data) throws -> [FloatcutSyncWireMessage] {
        var messages: [FloatcutSyncWireMessage] = []
        var inputIndex = incoming.startIndex
        while inputIndex < incoming.endIndex {
            if buffer.count < 4 {
                let count = min(4 - buffer.count, incoming.distance(from: inputIndex, to: incoming.endIndex))
                let end = incoming.index(inputIndex, offsetBy: count)
                buffer.append(incoming[inputIndex..<end])
                inputIndex = end
                guard buffer.count == 4 else { break }
            }
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= UInt32(FloatcutSyncProtocol.maximumFrameBytes) else {
                throw FloatcutSyncProtocolError.invalidFrameLength(Int(length))
            }
            let total = 4 + Int(length)
            let count = min(total - buffer.count, incoming.distance(from: inputIndex, to: incoming.endIndex))
            if count > 0 {
                let end = incoming.index(inputIndex, offsetBy: count)
                buffer.append(incoming[inputIndex..<end])
                inputIndex = end
            }
            guard buffer.count == total else { continue }
            let payload = buffer.subdata(in: 4..<total)
            buffer.removeAll(keepingCapacity: true)
            messages.append(try FloatcutSyncCodec.decodePayload(payload))
        }
        return messages
    }

    mutating func finish() throws {
        guard buffer.isEmpty else {
            buffer.removeAll(keepingCapacity: false)
            throw FloatcutSyncProtocolError.incompleteFrame
        }
    }
}

private struct StrictJSONValidator {
    let bytes: [UInt8]
    var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw FloatcutSyncProtocolError.invalidJSON("trailing bytes") }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= FloatcutSyncProtocol.maximumJSONDepth, index < bytes.count else {
            if depth > FloatcutSyncProtocol.maximumJSONDepth { throw FloatcutSyncProtocolError.nestingTooDeep }
            throw FloatcutSyncProtocolError.invalidJSON("unexpected end")
        }
        switch bytes[index] {
        case 0x7b: try parseObject(depth: depth)
        case 0x5b: try parseArray(depth: depth)
        case 0x22: _ = try parseString()
        case 0x74: try consume("true")
        case 0x66: try consume("false")
        case 0x6e: try consume("null")
        case 0x2d, 0x30...0x39: try parseInteger()
        default: throw FloatcutSyncProtocolError.invalidJSON("unexpected token")
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consumeIf(0x7d) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw FloatcutSyncProtocolError.invalidJSON("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw FloatcutSyncProtocolError.duplicateJSONKey(key) }
            skipWhitespace()
            guard consumeIf(0x3a) else { throw FloatcutSyncProtocolError.invalidJSON("missing colon") }
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x7d) { return }
            guard consumeIf(0x2c) else { throw FloatcutSyncProtocolError.invalidJSON("object separator") }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consumeIf(0x5d) { return }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x5d) { return }
            guard consumeIf(0x2c) else { throw FloatcutSyncProtocolError.invalidJSON("array separator") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                if byte == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) })
                    else { throw FloatcutSyncProtocolError.invalidJSON("unicode escape") }
                    index += 5
                } else {
                    guard [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(byte) else {
                        throw FloatcutSyncProtocolError.invalidJSON("escape")
                    }
                    index += 1
                }
                escaped = false
            } else if byte == 0x5c {
                escaped = true
                index += 1
            } else if byte == 0x22 {
                index += 1
                let raw = Data(bytes[start..<index])
                guard let decoded = try? JSONSerialization.jsonObject(with: Data("[".utf8) + raw + Data("]".utf8)) as? [String],
                      let value = decoded.first
                else { throw FloatcutSyncProtocolError.invalidJSON("string") }
                return value
            } else {
                guard byte >= 0x20 else { throw FloatcutSyncProtocolError.invalidJSON("control in string") }
                index += 1
            }
        }
        throw FloatcutSyncProtocolError.invalidJSON("unterminated string")
    }

    private mutating func parseInteger() throws {
        if consumeIf(0x2d), index == bytes.count { throw FloatcutSyncProtocolError.invalidJSON("number") }
        if consumeIf(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw FloatcutSyncProtocolError.invalidJSON("leading zero")
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw FloatcutSyncProtocolError.invalidJSON("number")
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, [0x2e, 0x45, 0x65].contains(bytes[index]) {
            throw FloatcutSyncProtocolError.nonIntegerJSONNumber
        }
    }

    private mutating func consume(_ literal: String) throws {
        let data = Array(literal.utf8)
        guard index + data.count <= bytes.count, Array(bytes[index..<(index + data.count)]) == data else {
            throw FloatcutSyncProtocolError.invalidJSON(literal)
        }
        index += data.count
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }
}
