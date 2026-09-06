import Foundation
import CryptoKit
import ImageIO

/// May be read by the main thread/worker and invalidated by the network queue.
/// The final active check admits an import on the main thread. Cancellation
/// prevents later admissions; an already admitted UI operation is not rolled back.
final class FloatcutSyncWorkToken {
    private let lock = NSLock()
    private var cancelled = false
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// Network-queue owned, one online preparation per peer; never an offline queue.
final class FloatcutSyncImagePreparation {
    private var current: FloatcutSyncWorkToken?
    func reserve() -> FloatcutSyncWorkToken? {
        guard current == nil else { return nil }
        let token = FloatcutSyncWorkToken()
        current = token
        return token
    }
    func consume(_ token: FloatcutSyncWorkToken) -> Bool {
        guard current === token, token.isActive else { return false }
        current = nil
        token.cancel()
        return true
    }
    func cancel() {
        current?.cancel()
        current = nil
    }
}

/// Owned exclusively by the network queue. Only one clipboard operation per
/// connection runs at once. Control messages bypass this inbox. Stop requesting
/// network reads at the high-water mark (one already decoded batch may exceed it).
final class FloatcutSyncOrderedInbox {
    private struct Entry {
        let bytes: Int
        let start: (@escaping () -> Void) -> Void
    }
    private var entries: [Entry] = []
    private var generation = 0
    private(set) var pendingBytes = 0
    private(set) var isProcessing = false
    var didProgress: (() -> Void)?
    var canReceive: Bool { pendingBytes < 2 * FloatcutSyncProtocol.maximumFrameBytes && entries.count < 128 }
    var isEmpty: Bool { !isProcessing && entries.isEmpty }

    func enqueue(bytes: Int, start: @escaping (@escaping () -> Void) -> Void) {
        entries.append(Entry(bytes: bytes, start: start))
        pendingBytes += bytes
        drain()
    }

    func discard() {
        generation += 1
        entries.removeAll()
        pendingBytes = 0
        isProcessing = false
    }

    private func drain() {
        guard !isProcessing, !entries.isEmpty else { return }
        isProcessing = true
        let entry = entries.removeFirst()
        let currentGeneration = generation
        var completed = false
        entry.start { [weak self] in
            guard let self, !completed, self.generation == currentGeneration else { return }
            completed = true
            self.pendingBytes -= entry.bytes
            self.isProcessing = false
            self.drain()
            self.didProgress?()
        }
    }
}

/// Serial disk work, never on the network or main queue. Each connection admits
/// only one operation, so neither chunks nor open/write/close can race or pile up.
enum FloatcutSyncImageWork {
    static let queue = DispatchQueue(label: "de.meierkarsten.floatcut.sync.image-io", qos: .utility)
    static let preparation: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "de.meierkarsten.floatcut.sync.image-preparation"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
}

final class FloatcutIncomingImageFile {
    let clipID: String
    let contentType: String
    let byteSize: Int
    let contentSHA256: String
    let chunkCount: Int
    let token: FloatcutSyncWorkToken
    private var fileURL: URL
    private var handle: FileHandle?
    private var nextChunkIndex = 0
    private var receivedBytes = 0
    private var hasher = SHA256()

    init(message: FloatcutSyncWireMessage, token: FloatcutSyncWorkToken = FloatcutSyncWorkToken(), directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("de.meierkarsten.floatcut-sync-v2", isDirectory: true)) throws {
        guard token.isActive else { throw FloatcutSyncProtocolError.invalidState }
        clipID = try message.string("clip_id")
        self.token = token
        contentType = try message.string("content_type")
        byteSize = Int(try message.integer("byte_size"))
        contentSHA256 = try message.string("content_sha256")
        chunkCount = Int(try message.integer("chunk_count"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { handle = try FileHandle(forWritingTo: fileURL) }
        catch { try? FileManager.default.removeItem(at: fileURL); throw error }
    }

    func append(_ message: FloatcutSyncWireMessage) throws {
        guard token.isActive, let handle, try message.string("clip_id") == clipID,
              Int(try message.integer("chunk_index")) == nextChunkIndex,
              let chunk = message.validatedImageChunk,
              chunk.count == min(FloatcutSyncProtocol.imageChunkBytes, byteSize - receivedBytes),
              nextChunkIndex < chunkCount else { throw FloatcutSyncProtocolError.invalidState }
        try handle.write(contentsOf: chunk)
        hasher.update(data: chunk)
        receivedBytes += chunk.count
        nextChunkIndex += 1
    }

    func finish() throws -> Data {
        guard token.isActive, let handle else { throw FloatcutSyncProtocolError.invalidState }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        let hash = Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
        guard receivedBytes == byteSize, nextChunkIndex == chunkCount, hash == contentSHA256 else {
            throw FloatcutSyncProtocolError.hashMismatch
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard Self.validImage(data, contentType: contentType) else {
            throw FloatcutSyncProtocolError.invalidField("image")
        }
        let validatedURL = fileURL.deletingPathExtension().appendingPathExtension("validated")
        try FileManager.default.moveItem(at: fileURL, to: validatedURL)
        fileURL = validatedURL
        return data
    }

    func cleanup() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func validImage(_ data: Data, contentType: String) -> Bool {
        let signatureOK = contentType == "image/png"
            ? data.starts(with: FloatcutSyncProtocol.pngSignature)
            : data.starts(with: FloatcutSyncProtocol.jpegSignature)
        guard signatureOK, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        let pixels = width.uint64Value.multipliedReportingOverflow(by: height.uint64Value)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return !pixels.overflow && !bytes.overflow && pixels.partialValue <= 100_000_000 && bytes.partialValue <= 512_000_000
    }
}
