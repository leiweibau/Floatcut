import CryptoKit
import Darwin
import Foundation

/// The journal is private, versioned metadata. It never stores an accept token.
/// Transactions run on disk workers; the lock serializes atomic journal updates.
final class FloatcutFileTransferJournal {
    struct Record: Codable, Equatable {
        var manifest: FloatcutFileManifest
        var direction: FloatcutFileTransferDirection
        var peerID: String
        var peerPin: String
        var trustGeneration: UInt64
        var peerName: String
        var state: String // outbound, accepted, prepared, saved, failed, cancelled
        var reason: String?
        var destinationDirectory: String?
        var destinationIdentity: FloatcutFileStorage.Identity?
        var stagingLeaf: String?
        var finalLeaf: String?
        var fileIdentity: FloatcutFileStorage.Identity?
        var terminalAtMilliseconds: Int64?
    }
    private struct Document: Codable { let version: Int; let records: [Record] }
    let directory: URL
    private let lock = NSLock()
    private var entries: [String: Record] = [:]
    private var loaded = false
    private var ownerFD: Int32 = -1
    private let wallClock: () -> Int64

    init(directory: URL, wallClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.directory = directory; self.wallClock = wallClock
    }
    deinit { if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD) } }

    /// Only after the old engine's entire worker/callback set has drained.
    /// Prepared evidence then passes to a replacing recovery owner.
    func relinquishOwnership() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD); ownerFD = -1 }
    }

    func loadAndReconcile(nowMilliseconds: Int64) throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dirFD = try FloatcutFileStorage.openDirectory(directory)
        defer { close(dirFD) }
        try FloatcutFileStorage.makePrivate(dirFD, mode: 0o700)
        // One engine owns a journal epoch until all of its captured workers and
        // publication grants have resolved. A replacing engine waits on its
        // disk pool, while the control executor remains responsive.
        let owner = openat(dirFD, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard owner >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        var ownerInfo = stat()
        guard fstat(owner, &ownerInfo) == 0, ownerInfo.st_mode & S_IFMT == S_IFREG, ownerInfo.st_uid == getuid() else {
            close(owner); throw FloatcutFileFailure.reason("io_error")
        }
        do { try FloatcutFileStorage.makePrivate(owner, mode: 0o600) } catch { close(owner); throw error }
        guard flock(owner, LOCK_EX) == 0 else { close(owner); throw FloatcutFileFailure.reason("io_error") }
        ownerFD = owner
        let documentFD = openat(dirFD, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if documentFD >= 0 {
            defer { close(documentFD) }
            var info = stat()
            guard fstat(documentFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_size >= 0, info.st_size <= 8_388_608 else { throw FloatcutFileFailure.reason("io_error") }
            let handle = FileHandle(fileDescriptor: documentFD, closeOnDealloc: false)
            let bytes = try handle.readToEnd() ?? Data()
            let doc = try JSONDecoder().decode(Document.self, from: bytes)
            guard doc.version == 1 else { throw FloatcutFileFailure.reason("io_error") }
            for record in doc.records {
                guard record.manifest.byteSize >= 0, record.manifest.byteSize <= 8_589_934_592,
                      FloatcutSyncProtocol.isCanonicalUUID(record.manifest.transferID),
                      FloatcutSyncProtocol.isCanonicalUUID(record.peerID), record.trustGeneration > 0,
                      record.terminalAtMilliseconds.map({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) ?? true,
                      record.direction == .outgoing ? record.state == "outbound"
                        : ["accepted", "prepared", "saved", "failed", "cancelled"].contains(record.state) else {
                    throw FloatcutFileFailure.reason("io_error")
                }
                // Retired outcomes do not consume restart capacity. Historical
                // journal rows are pruned before enforcing retained quotas.
                if let timestamp = record.terminalAtMilliseconds, nowMilliseconds >= timestamp + 86_400_000 { continue }
                guard entries[record.manifest.transferID] == nil else { throw FloatcutFileFailure.reason("io_error") }
                entries[record.manifest.transferID] = record
            }
            guard entries.values.filter({ $0.direction == .incoming }).count <= 1024,
                  entries.values.filter({ $0.direction == .outgoing }).count <= 1024 else { throw FloatcutFileFailure.reason("io_error") }
        } else if errno != ENOENT { throw FloatcutFileFailure.reason("io_error") }
        // Snapshots are never byte-resumed after restart. Names are local random leaves.
        for leaf in try FileManager.default.contentsOfDirectory(atPath: directory.path) where leaf.hasPrefix("snapshot-") {
            unlinkat(dirFD, leaf, 0)
        }
        for (id, var record) in entries {
            if let timestamp = record.terminalAtMilliseconds, nowMilliseconds >= timestamp + 86_400_000 {
                entries.removeValue(forKey: id); continue
            }
            if record.direction == .outgoing {
                record.state = "outbound"; entries[id] = record; continue
            }
            if record.state == "saved" || record.state == "failed" || record.state == "cancelled" { continue }
            if record.state == "prepared" {
                do {
                    if try verifyPublished(record) {
                        record.state = "saved"; record.reason = nil
                    } else {
                        record.state = "failed"; record.reason = "control_lost"; try cleanupPrivate(record)
                    }
                } catch {
                    // Foreign final files (even with identical bytes) are untouched.
                    record.state = "failed"; record.reason = "io_error"
                }
            } else {
                record.state = "failed"; record.reason = "control_lost"; try? cleanupPrivate(record)
            }
            record.terminalAtMilliseconds = nowMilliseconds
            entries[id] = record
        }
        try persistLocked(dirFD: dirFD)
        loaded = true
        return Array(entries.values)
    }

    func put(_ record: Record) throws {
        lock.lock(); defer { lock.unlock() }
        guard loaded else { throw FloatcutFileFailure.reason("io_error") }
        let now = wallClock()
        // Every durable mutation compacts expired receipts. Prepared grants and
        // accepted reservations have no terminal timestamp and remain owned.
        entries = entries.filter { _, value in value.terminalAtMilliseconds.map { now < $0 + 86_400_000 } ?? true }
        let previous = entries[record.manifest.transferID]
        // Stale disk jobs cannot replace a terminal outcome with an accepted
        // or prepared state. Cancellation and preparation may race on workers.
        if let previous, ["saved", "failed", "cancelled"].contains(previous.state) {
            guard previous == record else { throw FloatcutFileFailure.reason("invalid_state") }
            return // Idempotence never renews the first terminal retention time.
        }
        entries[record.manifest.transferID] = record
        do { try persistLocked() } catch {
            entries[record.manifest.transferID] = previous; throw error
        }
    }

    func removeOutbound(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard entries[id]?.direction == .outgoing else { return }
        let previous = entries.removeValue(forKey: id)
        do { try persistLocked() } catch { entries[id] = previous; throw error }
    }

    private func persistLocked(dirFD retained: Int32? = nil) throws {
        let fd = try retained ?? FloatcutFileStorage.openDirectory(directory)
        defer { if retained == nil { close(fd) } }
        let bytes = try JSONEncoder().encode(Document(version: 1, records: entries.values.sorted { $0.manifest.transferID < $1.manifest.transferID }))
        let leaf = ".journal-\(UUID().uuidString.lowercased())"
        let documentFD = openat(fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard documentFD >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        defer { close(documentFD); unlinkat(fd, leaf, 0) }
        try FloatcutFileStorage.makePrivate(documentFD, mode: 0o600)
        try FloatcutFileStorage.writeAll(documentFD, data: bytes)
        try FloatcutFileStorage.flush(documentFD)
        guard renameat(fd, leaf, fd, "journal.json") == 0, fsync(fd) == 0 else { throw FloatcutFileFailure.reason("io_error") }
    }

    private func verifyPublished(_ record: Record) throws -> Bool {
        guard let directoryPath = record.destinationDirectory, let final = record.finalLeaf, let identity = record.fileIdentity,
              let directoryIdentity = record.destinationIdentity, !final.contains("/"), final != ".", final != ".." else {
            throw FloatcutFileFailure.reason("io_error")
        }
        let directoryFD = try FloatcutFileStorage.openDirectory(URL(fileURLWithPath: directoryPath))
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, FloatcutFileStorage.identity(directoryInfo) == directoryIdentity else {
            throw FloatcutFileFailure.reason("io_error")
        }
        let fd = openat(directoryFD, final, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return false }
        guard fd >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FloatcutFileStorage.identity(info) == identity, info.st_size == record.manifest.byteSize else {
            throw FloatcutFileFailure.reason("io_error")
        }
        var hasher = SHA256(); var bytes = [UInt8](repeating: 0, count: 262_144)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw FloatcutFileFailure.reason("io_error") }
            if count == 0 { break }
            hasher.update(data: Data(bytes[0..<count]))
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == record.manifest.contentSHA256 else { throw FloatcutFileFailure.reason("io_error") }
        try FloatcutFileStorage.flush(fd)
        guard fsync(directoryFD) == 0 else { throw FloatcutFileFailure.reason("io_error") }
        return true
    }

    private func cleanupPrivate(_ record: Record) throws {
        guard let path = record.destinationDirectory, let leaf = record.stagingLeaf,
              leaf.hasPrefix(".floatcut-"), !leaf.contains("/") else { return }
        let fd = try FloatcutFileStorage.openDirectory(URL(fileURLWithPath: path)); defer { close(fd) }
        var directoryInfo = stat()
        guard fstat(fd, &directoryInfo) == 0, FloatcutFileStorage.identity(directoryInfo) == record.destinationIdentity else { return }
        let stagedFD = openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if stagedFD >= 0 { unlinkat(stagedFD, FloatcutFileStorage.payloadLeaf, 0); close(stagedFD) }
        unlinkat(fd, leaf, AT_REMOVEDIR)
    }
}
