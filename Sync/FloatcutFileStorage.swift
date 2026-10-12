import CryptoKit
import Darwin
import Foundation

/// All methods below perform blocking I/O and belong on the bounded disk pool.
/// File descriptors, rather than re-resolved paths, carry publication authority.
final class FloatcutFileStorage {
    struct Identity: Codable, Equatable { let device: Int32; let inode: UInt64 }
    final class Snapshot {
        private var descriptor: Int32
        let url: URL
        let byteSize: Int64
        let contentSHA256: String
        private let lock = NSLock()
        init(descriptor: Int32, url: URL, byteSize: Int64, contentSHA256: String) {
            self.descriptor = descriptor; self.url = url; self.byteSize = byteSize; self.contentSHA256 = contentSHA256
        }
        deinit { if descriptor >= 0 { close(descriptor) } }
        func remove() {
            lock.lock(); defer { lock.unlock() }
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            try? FileManager.default.removeItem(at: url)
        }
        /// Prefix and raw bytes share one allocation, including while a slow
        /// transport owns the send buffer. Cleanup cannot close a reused fd.
        func dataRecord(offset: Int64, count: Int) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard descriptor >= 0 else { throw FloatcutFileFailure.reason("io_error") }
            var record = Data(count: 13 + count)
            record[0] = 1
            var length = UInt32(count + 8).bigEndian; var position = UInt64(offset).bigEndian
            withUnsafeBytes(of: &length) { record.replaceSubrange(1..<5, with: $0) }
            withUnsafeBytes(of: &position) { record.replaceSubrange(5..<13, with: $0) }
            try record.withUnsafeMutableBytes { raw in
                var total = 0
                while total < count {
                    let readCount = pread(descriptor, raw.baseAddress!.advanced(by: 13 + total), count - total, off_t(offset + Int64(total)))
                    if readCount < 0 && errno == EINTR { continue }
                    guard readCount > 0 else { throw FloatcutFileFailure.reason("io_error") }
                    total += readCount
                }
            }
            return record
        }
        func rawBytes(offset: Int64, count: Int) throws -> Data {
            var record = try dataRecord(offset: offset, count: count)
            record.removeFirst(13); return record
        }
    }
    let directoryURL: URL
    let finalLeaf: String
    let stagingLeaf: String
    let directoryIdentity: Identity
    private(set) var identity: Identity?
    private let destinationFD: Int32
    private let stagingFD: Int32
    private var fileFD: Int32 = -1
    private var published = false
    private var hasher = SHA256()
    private var written: Int64 = 0
    private let lock = NSLock()
    static let payloadLeaf = "payload"

    init(directory: URL, finalLeaf: String, requiredBytes: Int64) throws {
        guard directory.isFileURL, !finalLeaf.isEmpty, !finalLeaf.contains("/"), finalLeaf != ".", finalLeaf != "..", finalLeaf.utf8.count <= 255 else {
            throw FloatcutFileFailure.reason("unsupported_destination")
        }
        let directoryFD = try Self.openDirectory(directory)
        var destinationInfo = stat()
        guard fstat(directoryFD, &destinationInfo) == 0 else { close(directoryFD); throw FloatcutFileFailure.reason("io_error") }
        // Preserve the contract's acceptance rejection order: existing, support, space.
        var existing = stat()
        if fstatat(directoryFD, finalLeaf, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            close(directoryFD); throw FloatcutFileFailure.reason("destination_exists")
        }
        var filesystem = statfs()
        guard fstatfs(directoryFD, &filesystem) == 0 else { close(directoryFD); throw FloatcutFileFailure.reason("unsupported_destination") }
        let filesystemName = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard filesystemName == "apfs", filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            close(directoryFD); throw FloatcutFileFailure.reason("unsupported_destination")
        }
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard !available.overflow, available.partialValue >= UInt64(requiredBytes) + 1_048_576 else {
            close(directoryFD); throw FloatcutFileFailure.reason("no_space")
        }
        let privateLeaf = ".floatcut-\(UUID().uuidString.lowercased())"
        guard mkdirat(directoryFD, privateLeaf, 0o700) == 0 else { close(directoryFD); throw FloatcutFileFailure.reason("io_error") }
        let privateFD = openat(directoryFD, privateLeaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard privateFD >= 0 else {
            unlinkat(directoryFD, privateLeaf, AT_REMOVEDIR); close(directoryFD); throw FloatcutFileFailure.reason("io_error")
        }
        do { try Self.makePrivate(privateFD, mode: 0o700) } catch {
            close(privateFD); unlinkat(directoryFD, privateLeaf, AT_REMOVEDIR); close(directoryFD); throw error
        }
        directoryURL = directory
        self.finalLeaf = finalLeaf
        stagingLeaf = privateLeaf
        destinationFD = directoryFD
        stagingFD = privateFD
        directoryIdentity = Self.identity(destinationInfo)
    }

    deinit { if fileFD >= 0 { close(fileFD) }; close(stagingFD); close(destinationFD) }

    /// This is called only after serialized one-time OPEN token claim.
    func createPayload() throws {
        lock.lock(); defer { lock.unlock() }
        guard fileFD == -1 else { throw FloatcutFileFailure.reason("invalid_state") }
        let fd = openat(stagingFD, Self.payloadLeaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FloatcutFileFailure.reason(errno == ENOSPC ? "no_space" : "io_error") }
        do {
            try Self.makePrivate(fd, mode: 0o600)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                throw FloatcutFileFailure.reason("io_error")
            }
            fileFD = fd; identity = Self.identity(info)
        } catch { close(fd); unlinkat(stagingFD, Self.payloadLeaf, 0); throw error }
    }

    func write(_ bytes: Data, offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard fileFD >= 0, !published, offset == written else { throw FloatcutFileFailure.reason("invalid_data") }
        try Self.writeAll(fileFD, data: bytes)
        hasher.update(data: bytes)
        written += Int64(bytes.count)
    }

    func verify(manifest: FloatcutFileManifest) throws -> Identity {
        lock.lock(); defer { lock.unlock() }
        guard written == manifest.byteSize else { throw FloatcutFileFailure.reason("size_mismatch") }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.contentSHA256 else { throw FloatcutFileFailure.reason("hash_mismatch") }
        var info = stat()
        guard fileFD >= 0, fstat(fileFD, &info) == 0, Self.identity(info) == identity, info.st_size == manifest.byteSize else {
            throw FloatcutFileFailure.reason("io_error")
        }
        return Self.identity(info)
    }

    func flushPayload() throws {
        lock.lock(); defer { lock.unlock() }
        guard fileFD >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        try Self.flush(fileFD)
    }

    func verifyAndFlush(manifest: FloatcutFileManifest) throws -> Identity {
        let identity = try verify(manifest: manifest)
        try flushPayload()
        return identity
    }

    /// Call only after the authority queue's irrevocable publication grant.
    /// A successful rename followed by durability failure retains prepared evidence.
    func publish() throws {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        var staged = stat()
        guard fstat(fileFD, &info) == 0, Self.identity(info) == identity,
              fstatat(stagingFD, Self.payloadLeaf, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              Self.identity(staged) == identity else { throw FloatcutFileFailure.reason("io_error") }
        guard renameatx_np(stagingFD, Self.payloadLeaf, destinationFD, finalLeaf, UInt32(RENAME_EXCL)) == 0 else {
            throw FloatcutFileFailure.reason(errno == EEXIST ? "destination_exists" : "io_error")
        }
        published = true
        try Self.flush(fileFD)
        guard fsync(destinationFD) == 0 else { throw FloatcutFileFailure.reason("publication_unconfirmed") }
        unlinkat(destinationFD, stagingLeaf, AT_REMOVEDIR)
    }

    var didPublish: Bool { lock.lock(); defer { lock.unlock() }; return published }
    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        // Never remove finalLeaf. Cleanup has authority over private bytes only.
        if !published { unlinkat(stagingFD, Self.payloadLeaf, 0) }
        if fileFD >= 0 { close(fileFD); fileFD = -1 }
        unlinkat(destinationFD, stagingLeaf, AT_REMOVEDIR)
    }

    static func snapshot(source: URL, in privateDirectory: URL) throws -> Snapshot {
        guard source.isFileURL else { throw FloatcutFileFailure.reason("io_error") }
        // O_NONBLOCK prevents a selected FIFO from blocking before the regular-file check.
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        defer { close(sourceFD) }
        var info = stat()
        guard fstat(sourceFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw FloatcutFileFailure.reason("invalid_source") }
        guard info.st_size >= 0, info.st_size <= 8_589_934_592 else { throw FloatcutFileFailure.reason("too_large") }
        let directoryFD = try openDirectory(privateDirectory)
        defer { close(directoryFD) }
        let leaf = "snapshot-\(UUID().uuidString.lowercased())"
        let fd = openat(directoryFD, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        let url = privateDirectory.appendingPathComponent(leaf)
        do {
            try makePrivate(fd, mode: 0o600)
            var hasher = SHA256(); var total: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 262_144)
            while true {
                let count = read(sourceFD, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw FloatcutFileFailure.reason("io_error") }
                if count == 0 { break }
                total += Int64(count)
                guard total <= 8_589_934_592 else { throw FloatcutFileFailure.reason("too_large") }
                let chunk = Data(buffer[0..<count])
                try writeAll(fd, data: chunk); hasher.update(data: chunk)
            }
            try flush(fd)
            guard fchmod(fd, 0o400) == 0 else { throw FloatcutFileFailure.reason("io_error") }
            let readonly = openat(directoryFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard readonly >= 0 else { throw FloatcutFileFailure.reason("io_error") }
            close(fd)
            return Snapshot(descriptor: readonly, url: url, byteSize: total,
                            contentSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch { close(fd); unlinkat(directoryFD, leaf, 0); throw error }
    }

    static func readSnapshot(_ snapshot: Snapshot, offset: Int64, count: Int) throws -> Data {
        try snapshot.rawBytes(offset: offset, count: count)
    }

    /// Component-by-component resolution refuses symlink traversal and retains
    /// each next directory before releasing its parent, including for recovery.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw FloatcutFileFailure.reason("unsupported_destination") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FloatcutFileFailure.reason("io_error") }
        for component in url.path.split(separator: "/") {
            guard component != "..", component != "." else { close(fd); throw FloatcutFileFailure.reason("unsupported_destination") }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw FloatcutFileFailure.reason("unsupported_destination") }
            fd = next
        }
        return fd
    }
    static func identity(_ info: stat) -> Identity { Identity(device: info.st_dev, inode: info.st_ino) }
    static func makePrivate(_ fd: Int32, mode: mode_t) throws {
        guard fchmod(fd, mode) == 0 else { throw FloatcutFileFailure.reason("io_error") }
        guard let acl = acl_init(0) else { throw FloatcutFileFailure.reason("io_error") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(fd, acl) == 0 else { throw FloatcutFileFailure.reason("io_error") }
    }
    static func flush(_ fd: Int32) throws {
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw FloatcutFileFailure.reason("io_error") }
    }
    static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FloatcutFileFailure.reason(errno == ENOSPC ? "no_space" : "io_error") }
                offset += count
            }
        }
    }
}
