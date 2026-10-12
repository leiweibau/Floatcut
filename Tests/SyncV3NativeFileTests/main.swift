import Darwin
import CryptoKit
import Foundation
import Network
import Security

struct NativeTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NativeTestFailure(message) }
}

/// Maximum-size cases never materialize the complete source or received file.
/// One 1 MiB test buffer is separate from the engine's bounded DATA buffers.
func makeStreamingSource(at url: URL, byteSize: Int64) throws -> String {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw NativeTestFailure("Could not create streaming test source") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    let chunk = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    var remaining = byteSize
    var hasher = SHA256()
    while remaining > 0 {
        let count = Int(min(Int64(chunk.count), remaining))
        let bytes = count == chunk.count ? chunk : Data(chunk.prefix(count))
        try handle.write(contentsOf: bytes)
        hasher.update(data: bytes)
        remaining -= Int64(count)
    }
    guard fsync(descriptor) == 0 else { throw NativeTestFailure("Could not flush streaming test source") }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func streamingFileDigest(at url: URL, expectedByteSize: Int64) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw NativeTestFailure("Could not open streaming received file") }
    defer { close(descriptor) }
    var info = stat()
    try require(fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG,
                "Received maximum file was not a regular file")
    try require(info.st_size == expectedByteSize, "Received maximum file had the wrong size")
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    var total: Int64 = 0
    var hasher = SHA256()
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw NativeTestFailure("Could not read streaming received file") }
        if count == 0 { break }
        total += Int64(count)
        try require(total <= expectedByteSize, "Received maximum file exceeded the offered size")
        hasher.update(data: Data(buffer.prefix(count)))
    }
    try require(total == expectedByteSize, "Streaming verification read the wrong byte count")
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func cpuSeconds(_ usage: rusage) -> Double {
    Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

final class NativeFileClock: FloatcutSyncElapsedClock {
    private let lock = NSLock()
    private let continuous = FloatcutSyncContinuousClock()
    private var offset: TimeInterval = 0
    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return continuous.now() + offset
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); offset += seconds; lock.unlock()
    }
}

/// Every callback records under this condition. Tests can block on real events
/// without blocking either of the two serial protocol executors.
final class NativeFileObservations {
    struct Event {
        let sender: Int
        let type: String
        let transferID: String
        let status: String?
        let receivedBytes: Int64?
        let phase: String?
    }
    let condition = NSCondition()
    var snapshots: [[String: FloatcutFileTransferSnapshot]] = [[:], [:]]
    var history: [[FloatcutFileTransferSnapshot]] = [[], []]
    var engineReady = [false, false]
    var ports: [NWEndpoint.Port?] = [nil, nil]
    var fileConnections = [0, 0]
    var incomingFileConnections = [0, 0]
    var controlConnections = [0, 0]
    var events: [Event] = []
    var droppedResults: Set<String> = []
    var dropCounts: [String: Int] = [:]
    var advertisedBytes: [String: Set<Int64>] = [:]
    var failures: [String] = []

    func withLock<T>(_ operation: (NativeFileObservations) throws -> T) rethrows -> T {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        return try operation(self)
    }

    func wait(_ label: String, timeout: TimeInterval = 30,
              predicate: (NativeFileObservations) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !predicate(self) {
            if let failure = failures.first { throw NativeTestFailure(failure) }
            if !condition.wait(until: deadline) {
                let states = snapshots.enumerated().map { index, items in
                    "peer\(index): " + items.values.map { "\($0.fileName)=\($0.phase.rawValue)/\($0.reason ?? "none")" }.joined(separator: ", ")
                }.joined(separator: "; ")
                throw NativeTestFailure("Timed out waiting for \(label). \(states)")
            }
        }
        if let failure = failures.first { throw NativeTestFailure(failure) }
    }

    func record(_ updates: [FloatcutFileTransferSnapshot], peer: Int) {
        withLock { state in
            state.engineReady[peer] = true
            state.snapshots[peer] = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
            for snapshot in updates {
                if snapshot.direction == .outgoing && snapshot.receivedBytes > 0 && snapshot.phase != .saved {
                    if !state.advertisedBytes[snapshot.id, default: []].contains(snapshot.receivedBytes) {
                        state.failures.append("Sender displayed bytes that the receiver had not advertised: \(snapshot.receivedBytes)")
                    }
                }
                // Preserve distinct phase evidence for small/empty cases; an
                // 8 GiB stream must not make the observation harness itself grow
                // once per DATA record or retain duplicate full snapshot sets.
                if !state.history[peer].contains(where: {
                    $0.id == snapshot.id && $0.phase == snapshot.phase && $0.percentage == snapshot.percentage
                }) { state.history[peer].append(snapshot) }
            }
        }
    }
}

func nativeTLSParameters(identity: FloatcutSyncIdentity, expectedPeer: FloatcutSyncIdentity,
                         protocols: [String], queue: DispatchQueue) throws -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_peer_authentication_required(options, true)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    for name in protocols { sec_protocol_options_add_tls_application_protocol(options, name) }
    guard let local = sec_identity_create(identity.identity) else { throw NativeTestFailure("Could not create native TLS identity") }
    sec_protocol_options_set_local_identity(options, local)
    sec_protocol_options_set_verify_block(options, { metadata, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], chain.count == 1,
              let certificate = chain.first,
              SecCertificateCopyData(certificate) as Data == expectedPeer.certificateDER,
              FloatcutSyncCertificateValidator.validate(certificate: certificate, expectedDeviceID: expectedPeer.deviceID),
              sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv13,
              !sec_protocol_metadata_get_early_data_accepted(metadata)
        else { complete(false); return }
        complete(true)
    }, queue)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.allowLocalEndpointReuse = true
    return parameters
}

func negotiatedALPN(_ connection: NWConnection) -> String? {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
          let name = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) else { return nil }
    return String(cString: name)
}

final class NativeFileHarness {
    let observations = NativeFileObservations()
    let clock = NativeFileClock()
    let identities: [FloatcutSyncIdentity]
    let root: URL
    let queues = [DispatchQueue(label: "FloatcutV3NativeFile.a"), DispatchQueue(label: "FloatcutV3NativeFile.b")]
    var contexts: [FloatcutFilePeerContext] = []
    var engines: [FloatcutFileTransferEngine] = []
    var listeners: [NWListener] = []
    private var accepted: [[NWConnection]] = [[], []]
    private var probes: [[NWConnection]] = [[], []]

    init(identities: [FloatcutSyncIdentity], root: URL) throws {
        self.identities = identities
        self.root = root
        let binding = try FloatcutSyncProtocol.controlBinding(
            dialerDeviceID: identities[0].deviceID, dialerCertificateSHA256: identities[0].certificateSHA256,
            dialerNonce: FloatcutSyncProtocol.secureNonce(),
            listenerDeviceID: identities[1].deviceID, listenerCertificateSHA256: identities[1].certificateSHA256,
            listenerNonce: FloatcutSyncProtocol.secureNonce())
        let controlID = UUID()
        contexts = (0..<2).map { index in
            let remote = identities[1 - index]
            return FloatcutFilePeerContext(deviceID: remote.deviceID, name: "Native client \(1 - index)",
                certificateSHA256: remote.certificateSHA256, trustGeneration: 1, peerGeneration: 1,
                controlConnectionID: controlID, controlBindingSHA256: binding, engineEpoch: 1, mutualFileCapability: true)
        }
        for index in 0..<2 {
            let destination = destinationDirectory(index)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let engine = FloatcutFileTransferEngine(queue: queues[index], localDeviceID: identities[index].deviceID,
                localCertificateSHA256: identities[index].certificateSHA256, epoch: 1,
                metadataDirectory: root.appendingPathComponent("metadata-\(index)", isDirectory: true), clock: clock,
                lookupPeer: { [weak self] id in
                    guard let self, self.contexts[index].deviceID == id else { return nil }
                    return self.contexts[index]
                },
                sendControl: { [weak self] peer, message in self?.deliverControl(message, from: index, peer: peer) },
                connectFile: { [weak self] peer in
                    guard let self, peer == self.contexts[index] else { throw NativeTestFailure("File connection used stale peer context") }
                    guard let port = self.observations.withLock({ $0.ports[1 - index] }) else { throw NativeTestFailure("File listener has no port") }
                    self.observations.withLock { $0.fileConnections[index] += 1 }
                    return NWConnection(host: "127.0.0.1", port: port, using: try nativeTLSParameters(
                        identity: identities[index], expectedPeer: identities[1 - index],
                        protocols: ["floatcut-file/1"], queue: self.queues[index]))
                }, onSnapshots: { [weak self] updates in self?.observations.record(updates, peer: index) })
            engines.append(engine)
        }
    }

    func destinationDirectory(_ index: Int) -> URL { root.appendingPathComponent("received-\(index)", isDirectory: true) }

    func start() throws {
        for index in 0..<2 {
            let parameters = try nativeTLSParameters(identity: identities[index], expectedPeer: identities[1 - index],
                protocols: ["floatcut-sync/3", "floatcut-file/1"], queue: queues[index])
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters, on: .any)
            listeners.append(listener)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accepted[index].append(connection)
                let startedAt = self.clock.now()
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state {
                    case .ready:
                        switch negotiatedALPN(connection) {
                        case "floatcut-file/1":
                            self.observations.withLock { $0.incomingFileConnections[index] += 1 }
                            connection.stateUpdateHandler = nil
                            self.engines[index].acceptIncoming(connection, peer: self.contexts[index], candidateStartedAt: startedAt)
                        case "floatcut-sync/3":
                            self.observations.withLock { $0.controlConnections[index] += 1 }
                        default:
                            self.observations.withLock { $0.failures.append("Listener accepted unexpected ALPN") }
                            connection.cancel()
                        }
                    case .failed(let error): self.observations.withLock { $0.failures.append("Incoming native TLS connection failed: \(error)") }
                    default: break
                    }
                }
                connection.start(queue: self.queues[index])
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready: self.observations.withLock { $0.ports[index] = listener?.port }
                case .failed(let error): self.observations.withLock { $0.failures.append("Native listener failed: \(error)") }
                default: break
                }
            }
            listener.start(queue: queues[index])
        }
        try observations.wait("both listeners and recovered engines") {
            $0.ports.allSatisfy { $0 != nil } && $0.engineReady.allSatisfy { $0 }
        }
        // Both purpose-specific ALPNs use each listener's one SRV port.
        for index in 0..<2 { try connectControlProbe(from: index) }
        try observations.wait("control ALPN routed on both listener ports") { $0.controlConnections == [1, 1] }
    }

    private func connectControlProbe(from index: Int) throws {
        guard let port = observations.withLock({ $0.ports[1 - index] }) else { throw NativeTestFailure("Missing control listener port") }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try nativeTLSParameters(
            identity: identities[index], expectedPeer: identities[1 - index], protocols: ["floatcut-sync/3"], queue: queues[index]))
        queues[index].sync { probes[index].append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if negotiatedALPN(connection) != "floatcut-sync/3" {
                    self.observations.withLock { $0.failures.append("Control dialer negotiated wrong ALPN") }
                }
            case .failed(let error): self.observations.withLock { $0.failures.append("Control probe TLS failed: \(error)") }
            default: break
            }
        }
        connection.start(queue: queues[index])
    }

    /// Control delivery uses the strict wire codec and the authenticated peer
    /// context established for the native TLS pair. Its transport is a queue
    /// bridge; file data itself crosses actual native TLS sockets.
    private func deliverControl(_ message: FloatcutSyncWireMessage, from index: Int, peer: FloatcutFilePeerContext) {
        do {
            try require(peer == contexts[index], "Control send used stale authority")
            let frame = try FloatcutSyncCodec.encode(message)
            let decoded = try FloatcutSyncCodec.decodePayload(frame.subdata(in: 4..<frame.count))
            let id = (try? decoded.string("transfer_id")) ?? ""
            let shouldDrop = observations.withLock { state -> Bool in
                let bytes = try? decoded.integer("received_bytes")
                state.events.append(.init(sender: index, type: decoded.type, transferID: id,
                    status: try? decoded.string("status"), receivedBytes: bytes, phase: try? decoded.string("phase")))
                if let bytes { state.advertisedBytes[id, default: []].insert(bytes) }
                if decoded.type == "FILE_RESULT", (try? decoded.string("status")) == "saved", state.droppedResults.contains(id) {
                    state.dropCounts[id, default: 0] += 1
                    return true
                }
                return false
            }
            guard !shouldDrop else { return }
            let destination = 1 - index
            queues[destination].async { [weak self] in
                guard let self else { return }
                do { try self.engines[destination].handleControl(decoded, peer: self.contexts[destination]) }
                catch { self.observations.withLock { $0.failures.append("\(decoded.type) control handling failed: \(error)") } }
            }
        } catch { observations.withLock { $0.failures.append("Control codec rejected engine output: \(error)") } }
    }

    func send(size: Int, from sender: Int, reject: Bool = false, loseResult: Bool = false) throws {
        let receiver = 1 - sender
        let source = root.appendingPathComponent("source-\(sender)-\(size)-\(UUID().uuidString.lowercased()).bin")
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ sender) })
        try bytes.write(to: source)
        let connectionsBefore = observations.withLock { $0.fileConnections }
        let id = engines[sender].sendFile(url: source, peer: contexts[sender])
        try observations.wait("receiver's explicit approval prompt for \(size) bytes") { $0.snapshots[receiver][id]?.phase == .offered }
        let offered = try observations.withLock { state -> FloatcutFileTransferSnapshot in
            guard let offered = state.snapshots[receiver][id] else { throw NativeTestFailure("No offered transfer") }
            try require(state.fileConnections == connectionsBefore, "File channel opened before recipient approval")
            try require(offered.receivedBytes == 0, "Data received before recipient approval")
            if loseResult { state.droppedResults.insert(id) }
            return offered
        }
        // Give all asynchronously queued work a chance to run. An offer alone
        // must remain inert regardless of either device's UUID ordering.
        usleep(150_000)
        try observations.withLock { state in
            try require(state.fileConnections == connectionsBefore, "Unapproved offer started a delayed file channel")
            try require(state.snapshots[receiver][id]?.phase == .offered, "Offer did not wait for approval")
        }

        if reject {
            engines[receiver].reject(id: id, revision: offered.revision)
            try observations.wait("explicit reject propagated") {
                $0.snapshots[receiver][id]?.phase == .rejected && $0.snapshots[sender][id]?.phase == .rejected
            }
            try observations.withLock { state in
                try require(state.fileConnections == connectionsBefore, "Rejected offer opened a file channel")
                try require(state.snapshots[sender][id]?.reason == "user_rejected", "User rejection lost its reason")
            }
            print("Native file reject passed (sender \(sender)).")
            return
        }

        engines[receiver].accept(id: id, directory: destinationDirectory(receiver), revision: offered.revision)
        try observations.wait("receiver durable saved result for \(size) bytes", timeout: 60) { $0.snapshots[receiver][id]?.phase == .saved }
        if loseResult {
            try observations.withLock { state in
                try require(state.dropCounts[id, default: 0] >= 1, "No result was dropped")
                try require(state.snapshots[sender][id]?.phase != .saved, "Sender reported success without receiving the result")
            }
            clock.advance(46)
            queues[sender].sync { engines[sender].reconcileDeadlines() }
            try observations.wait("lost result becomes unconfirmed") { $0.snapshots[sender][id]?.phase == .unconfirmed }
            let statusConnections = observations.withLock { state -> [Int] in
                state.droppedResults.remove(id)
                return state.fileConnections
            }
            engines[sender].refreshStatus(id: id)
            try observations.wait("read-only receipt status resolves lost result") { $0.snapshots[sender][id]?.phase == .saved }
            try observations.withLock { state in
                try require(state.fileConnections == statusConnections, "Status query retransmitted file data")
                try require(state.events.contains { $0.type == "FILE_STATUS_REQUEST" && $0.transferID == id }, "No status request was sent")
            }
        } else {
            try observations.wait("sender received durable saved confirmation") { $0.snapshots[sender][id]?.phase == .saved }
        }
        let destination = destinationDirectory(receiver).appendingPathComponent("\(id)-\(source.lastPathComponent)")
        let received = try Data(contentsOf: destination)
        try require(received == bytes, "Published native file contents differed from the source")
        try observations.withLock { state in
            try require(state.snapshots[sender][id]?.receivedBytes == Int64(size), "Final sender progress did not match the receipt")
            try require(state.snapshots[receiver][id]?.receivedBytes == Int64(size), "Final receiver progress did not match bytes saved")
            try require(state.snapshots[sender][id]?.percentage == 100, "Final sender percentage was not 100")
            try require(state.events.contains { $0.type == "FILE_PROGRESS" && $0.transferID == id && $0.phase == "receiving" && $0.receivedBytes == 0 }, "Initial receiver progress was missing")
            try require(state.events.contains { $0.type == "FILE_PROGRESS" && $0.transferID == id && $0.phase == "committing" && $0.receivedBytes == Int64(size) }, "Commit receiver progress was missing")
            if size == 0 {
                try require(state.history[receiver].contains { $0.id == id && $0.phase == .receiving && $0.percentage == 0 }, "Empty file reported 100 percent before END")
            }
        }
        print("Native file \(loseResult ? "lost-result recovery" : "transfer") passed: \(size) bytes, sender \(sender).")
    }

    func sendMaximumFile() throws {
        let byteSize = FloatcutSyncProtocol.maximumFileBytes
        let source = root.appendingPathComponent("maximum-8gib-source.bin")
        defer { try? FileManager.default.removeItem(at: source) }
        let started = FloatcutSyncContinuousClock().now()
        var initialUsage = rusage()
        getrusage(RUSAGE_SELF, &initialUsage)
        let expectedHash = try makeStreamingSource(at: source, byteSize: byteSize)
        let prepared = FloatcutSyncContinuousClock().now()
        print(String(format: "Native maximum source prepared: %lld bytes, SHA256 %@, %.2f s", byteSize, expectedHash, prepared - started))
        fflush(stdout)

        let sender = 0
        let receiver = 1
        let connectionsBefore = observations.withLock { $0.fileConnections }
        let id = engines[sender].sendFile(url: source, peer: contexts[sender])
        let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        monitor.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        monitor.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.observations.withLock { $0.snapshots[receiver][id] ?? $0.snapshots[sender][id] }
            if let snapshot {
                print("Native maximum progress: \(snapshot.phase.rawValue), \(snapshot.receivedBytes)/\(byteSize) bytes, \(snapshot.percentage)%")
                fflush(stdout)
            }
        }
        monitor.resume()
        defer { monitor.cancel() }
        try observations.wait("maximum-file recipient approval", timeout: 1800) { $0.snapshots[receiver][id]?.phase == .offered }
        let offered = try observations.withLock { state -> FloatcutFileTransferSnapshot in
            guard let snapshot = state.snapshots[receiver][id] else { throw NativeTestFailure("Missing maximum offer") }
            try require(snapshot.byteSize == byteSize && snapshot.receivedBytes == 0, "Maximum offer size/approval state was wrong")
            try require(state.fileConnections == connectionsBefore, "Maximum file opened a channel before approval")
            return snapshot
        }
        engines[receiver].accept(id: id, directory: destinationDirectory(receiver), revision: offered.revision)
        try observations.wait("maximum-file receiver durable saved", timeout: 3600) { $0.snapshots[receiver][id]?.phase == .saved }
        try observations.wait("maximum-file sender saved receipt", timeout: 60) { $0.snapshots[sender][id]?.phase == .saved }
        let transferred = FloatcutSyncContinuousClock().now()
        let destination = destinationDirectory(receiver).appendingPathComponent("\(id)-\(source.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let actualHash = try streamingFileDigest(at: destination, expectedByteSize: byteSize)
        try require(actualHash == expectedHash, "Maximum file streaming hash differed from the source")
        try observations.withLock { state in
            try require(state.snapshots[sender][id]?.receivedBytes == byteSize && state.snapshots[receiver][id]?.receivedBytes == byteSize,
                        "Maximum file authoritative final byte counts differed")
            try require(state.snapshots[sender][id]?.percentage == 100 && state.snapshots[receiver][id]?.percentage == 100,
                        "Maximum file terminal percentages differed")
            try require(state.fileConnections[sender] == connectionsBefore[sender] + 1,
                        "Maximum file used more than one data channel")
            try require(state.events.contains { $0.type == "FILE_PROGRESS" && $0.transferID == id && $0.phase == "committing" && $0.receivedBytes == byteSize },
                        "Maximum file verified committing event was missing")
        }
        var finalUsage = rusage()
        getrusage(RUSAGE_SELF, &finalUsage)
        let finished = FloatcutSyncContinuousClock().now()
        print(String(format: "Native maximum file passed: %lld bytes, SHA256 %@, transfer %.2f s, total %.2f s, CPU %.2f s, process peak RSS %.2f MiB",
                     byteSize, actualHash, transferred - prepared, finished - started,
                     cpuSeconds(finalUsage) - cpuSeconds(initialUsage), Double(finalUsage.ru_maxrss) / 1_048_576))
        fflush(stdout)
    }

    func shutdown() {
        for index in 0..<engines.count {
            queues[index].sync {
                engines[index].shutdown()
                for connection in accepted[index] + probes[index] { connection.cancel() }
                if index < listeners.count { listeners[index].cancel() }
            }
        }
    }
}

let suffix = UUID().uuidString.lowercased()
let suites = (0..<2).map { "de.meierkarsten.floatcut.sync-v3-native-file.\(suffix).\($0)" }
let defaults = suites.map { UserDefaults(suiteName: $0)! }
let stores = (0..<2).map { index in
    FloatcutSyncIdentityStore(defaults: defaults[index], keyTag: Data("\(suites[index]).key".utf8),
        certificateLabel: "Floatcut V3 Native File Test \(suffix) \(index)")
}
let root = URL(fileURLWithPath: "/private/tmp/FloatcutV3NativeFile-\(suffix)", isDirectory: true)
var harness: NativeFileHarness?
var testSucceeded = false
do {
    defer {
        harness?.shutdown()
        for index in 0..<2 {
            do {
                try stores[index].reset()
                defaults[index].removePersistentDomain(forName: suites[index])
            } catch {
                // Keep the unique suite's references available for cleanup
                // rather than losing ownership of an isolated test key.
                fputs("Native test identity cleanup failed (\(suites[index])): \(error)\n", stderr)
                testSucceeded = false
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Sort two independently generated native identities, then transfer in both
    // directions. Data-channel initiation always follows the file sender.
    let identities = try stores.map { try $0.loadOrCreate() }.sorted { $0.deviceID < $1.deviceID }
    let pair = try NativeFileHarness(identities: identities, root: root)
    harness = pair
    try pair.start()
    for sender in 0..<2 {
        try pair.send(size: 17, from: sender, reject: true)
        for size in [0, 1, 262_143, 262_144, 262_145, 16_777_216] { try pair.send(size: size, from: sender) }
    }
    try pair.send(size: 262_145, from: 0, loseResult: true)
    if ProcessInfo.processInfo.environment["FLOATCUT_V3_MAXIMUM_FILE_TEST"] == "1" { try pair.sendMaximumFile() }
    testSucceeded = true
} catch {
    fputs("V3 native file integration failed: \(error)\n", stderr)
}
if !testSucceeded { exit(1) }
print("V3 native mutual-TLS/ALPN file integration tests passed.")
