import Foundation
import Network
import Security

/// Pull parser: the transport reads at most receiveBudget bytes and must consume
/// the returned record before asking for another. One record stays in flight.
struct FloatcutFileBinaryParser {
    enum Record { case data(offset: Int64, bytes: Data); case end(size: Int64, hash: String) }
    private var buffer = Data()
    private var payloadLength: Int?
    private var opcode: UInt8?
    private(set) var receivedBytes: Int64 = 0
    private(set) var ended = false
    let byteSize: Int64
    init(byteSize: Int64) { self.byteSize = byteSize }
    var receiveBudget: Int {
        if ended { return 0 }
        if payloadLength == nil { return 5 - buffer.count }
        // Receive and validate the DATA offset before allocating its bytes.
        if opcode == 1 && buffer.count < 13 { return 13 - buffer.count }
        return min(65_536, 5 + payloadLength! - buffer.count)
    }
    mutating func consume(_ bytes: Data) throws -> Record? {
        guard !ended, !bytes.isEmpty, bytes.count <= receiveBudget else { throw FloatcutFileFailure.reason("invalid_data") }
        buffer.append(bytes)
        if payloadLength == nil {
            guard buffer.count == 5 else { return nil }
            opcode = buffer[0]
            let length = buffer[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard opcode == 1 || opcode == 2 else { throw FloatcutFileFailure.reason("invalid_data") }
            if opcode == 1 {
                let expected = min(Int64(262_144), byteSize - receivedBytes)
                guard expected > 0, Int64(length) == expected + 8 else { throw FloatcutFileFailure.reason("invalid_data") }
            } else { guard length == 40 else { throw FloatcutFileFailure.reason("invalid_data") } }
            payloadLength = Int(length)
            return nil
        }
        if opcode == 1 && buffer.count == 13 {
            let offset = Self.uint64(buffer[5..<13])
            guard offset <= UInt64(Int64.max), Int64(offset) == receivedBytes else { throw FloatcutFileFailure.reason("invalid_data") }
        }
        guard buffer.count == payloadLength! + 5 else { return nil }
        let record: Record
        if opcode == 1 {
            let offset = receivedBytes
            buffer.removeFirst(13)
            let payload = buffer
            receivedBytes += Int64(payload.count)
            record = .data(offset: offset, bytes: payload)
        } else {
            let size = Self.uint64(buffer[5..<13])
            guard size <= UInt64(Int64.max), Int64(size) == byteSize, receivedBytes == byteSize else {
                throw FloatcutFileFailure.reason("size_mismatch")
            }
            let hash = buffer[13..<45].map { String(format: "%02x", $0) }.joined()
            ended = true
            record = .end(size: Int64(size), hash: hash)
        }
        buffer = Data(); opcode = nil; payloadLength = nil
        return record
    }
    func finishEOF() throws { guard ended else { throw FloatcutFileFailure.reason("invalid_data") } }
    static func uint64<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    static func dataRecord(offset: Int64, bytes: Data) -> Data {
        var result = Data([1]); append(UInt32(bytes.count + 8), to: &result); append(UInt64(offset), to: &result); result.append(bytes); return result
    }
    static func endRecord(size: Int64, hash: String) throws -> Data {
        guard hash.count == 64 else { throw FloatcutFileFailure.reason("invalid_data") }
        var result = Data([2]); append(UInt32(40), to: &result); append(UInt64(size), to: &result)
        var index = hash.startIndex
        while index < hash.endIndex {
            let next = hash.index(index, offsetBy: 2)
            guard let byte = UInt8(hash[index..<next], radix: 16) else { throw FloatcutFileFailure.reason("invalid_data") }
            result.append(byte); index = next
        }
        return result
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian; withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

/// One file ALPN channel, isolated from the control parser/writer/liveness.
/// All callbacks execute on the authority queue; disk work drives backpressure.
final class FloatcutFileDataConnection {
    let id = UUID()
    let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    private var prelude = Data()
    private var preludeLength: Int?
    var onClose: ((String) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    func startOutgoing(onReady: @escaping () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard self.hasFileALPN else { self.fail("channel_timeout"); return }
                onReady()
            case .failed, .cancelled: self.fail("channel_timeout")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    var hasFileALPN: Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let protocolName = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) else { return false }
        return String(cString: protocolName) == "floatcut-file/1"
    }

    func sendPrelude(_ message: FloatcutSyncWireMessage, completion: @escaping (Bool) -> Void) {
        do {
            let frame = try FloatcutSyncCodec.encode(message, maximumFrameBytes: 16_384)
            send(frame, completion: completion)
        } catch { completion(false); fail("invalid_data") }
    }

    func readPrelude(_ callback: @escaping (FloatcutSyncWireMessage) -> Void) {
        guard !closed else { return }
        let budget = preludeLength.map { 4 + $0 - prelude.count } ?? (4 - prelude.count)
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(16_384, budget)) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty, data.count <= budget else { self.fail("invalid_data"); return }
            self.prelude.append(data)
            if self.preludeLength == nil && self.prelude.count == 4 {
                let size = self.prelude.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size >= 1, size <= 16_384 else { self.fail("invalid_data"); return }
                self.preludeLength = Int(size)
            }
            if let length = self.preludeLength, self.prelude.count == 4 + length {
                do {
                    let payload = self.prelude.subdata(in: 4..<self.prelude.count)
                    self.prelude = Data()
                    callback(try FloatcutSyncCodec.decodePayload(payload, maximumFrameBytes: 16_384))
                } catch { self.fail("invalid_data") }
            } else if complete { self.fail("invalid_data") } else { self.readPrelude(callback) }
        }
    }

    func readBinary(maximumLength: Int, completion: @escaping (Data?, Bool) -> Void) {
        guard !closed, maximumLength > 0 else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, maximumLength)) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let error { _ = error; self.fail("invalid_data"); return }
            completion(data, complete)
        }
    }
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void) {
        guard !closed else { completion(false); return }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            completion(error == nil)
            if error != nil { self.fail("io_error") }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true; connection.stateUpdateHandler = nil; connection.cancel()
    }
    private func fail(_ reason: String) { guard !closed else { return }; close(); onClose?(reason) }
}
