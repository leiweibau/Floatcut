import AppKit
import CryptoKit
import Foundation
import ImageIO
import Network
import os.log
import Security

@objc public protocol FloatcutSyncClipboardDelegate: AnyObject {
    /// Called on the main thread. Return one of applied, duplicate, skipped, unsupported, invalid.
    func syncCoordinator(_ coordinator: FloatcutSyncCoordinator, didReceiveText text: String, peerName: String, peerDeviceID: String, clipID: String) -> String
    func syncCoordinator(_ coordinator: FloatcutSyncCoordinator, didReceiveImage data: Data, contentType: String, peerName: String, peerDeviceID: String, clipID: String) -> String
    func syncCoordinatorIsClipboardPaused(_ coordinator: FloatcutSyncCoordinator) -> Bool
}

struct FloatcutDiscoveredPeer: Identifiable, Equatable {
    let deviceID: String
    var name: String
    var platform: String
    var protocolVersion: Int
    var capabilities: [String]
    var allowsPairing: Bool
    var endpoint: NWEndpoint
    var id: String { deviceID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.name == rhs.name && lhs.platform == rhs.platform
            && lhs.protocolVersion == rhs.protocolVersion && lhs.capabilities == rhs.capabilities
            && lhs.allowsPairing == rhs.allowsPairing && lhs.endpoint == rhs.endpoint
    }
}

@objcMembers public final class FloatcutSyncCoordinator: NSObject, ObservableObject {
    public static let shared = FloatcutSyncCoordinator()

    @Published private(set) var discoveredPeers: [FloatcutDiscoveredPeer] = []
    @Published private(set) var pairedPeers: [FloatcutSyncPeer] = []
    @Published private(set) var revocations: [FloatcutSyncRevocation] = []
    @Published private(set) var onlineDeviceIDs: Set<String> = []
    @Published private(set) var statusText = NSLocalizedString("Synchronisation is disabled.", comment: "")
    @Published private(set) var securityWarning: String?
    @Published private(set) var identityResetRecommended = false
    @Published private(set) var localDeviceID = ""
    @Published private(set) var localCertificateSHA256 = ""

    public weak var clipboardDelegate: FloatcutSyncClipboardDelegate?

    private let peerStore = FloatcutSyncPersistentStore<FloatcutSyncPeer>(fileName: "peers-v2.json")
    private let revocationStore = FloatcutSyncPersistentStore<FloatcutSyncRevocation>(fileName: "revocations-v2.json")
    private let pendingStore = FloatcutSyncPersistentStore<FloatcutSyncPendingPairing>(fileName: "pending-pairings-v2.json")
    private let legacyPeerStore = FloatcutSyncPersistentStore<FloatcutSyncPeer>(fileName: "peers-v1.json")
    private let legacyRevocationStore = FloatcutSyncPersistentStore<FloatcutSyncRevocation>(fileName: "revocations-v1.json")
    private let legacyPendingStore = FloatcutSyncPersistentStore<FloatcutSyncPendingPairing>(fileName: "pending-pairings-v1.json")
    private let logger = Logger(subsystem: "de.meierkarsten.floatcut", category: "clipboard-sync")
    private var engine: FloatcutSyncEngine?

    private override init() {
        super.init()
        pairedPeers = peerStore.read()
        revocations = revocationStore.read()
        repairCompletedPendingPairings()
        purgeExpiredPendingPairings()
        showV2RepairingNoticeIfNeeded()
    }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "floatcutSyncEnabled")
    }

    public var allowsNewPairingRequests: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "floatcutSyncAllowsNewPairings") != nil else { return true }
        return defaults.bool(forKey: "floatcutSyncAllowsNewPairings")
    }

    public var isDiagnosticLoggingEnabled: Bool { FloatcutSyncDiagnostics.shared.isEnabled }

    public var diagnosticLogPath: String { FloatcutSyncDiagnostics.shared.logFileURL.path }

    public func setDiagnosticLoggingEnabled(_ enabled: Bool) {
        FloatcutSyncDiagnostics.shared.setEnabled(enabled)
        if enabled { recordDiagnostic("diagnostics_enabled", ["sync_enabled": isEnabled ? "true" : "false"]) }
        objectWillChange.send()
    }

    public func setAllowsNewPairingRequests(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: "floatcutSyncAllowsNewPairings")
        recordDiagnostic("pairing_requests_allowed_changed", ["allowed": allowed ? "true" : "false"])
        engine?.refreshAdvertisement()
        objectWillChange.send()
    }

    public var deviceName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "floatcutSyncDeviceName")
            let fallback = Host.current().localizedName ?? "Mac"
            return FloatcutSyncProtocol.truncateDeviceName(stored?.isEmpty == false ? stored! : fallback)
        }
        set {
            UserDefaults.standard.set(FloatcutSyncProtocol.truncateDeviceName(newValue), forKey: "floatcutSyncDeviceName")
            engine?.refreshAdvertisement()
            objectWillChange.send()
        }
    }

    public func startIfEnabled() {
        refreshStores()
        guard isEnabled else {
            statusText = NSLocalizedString("Synchronisation is disabled.", comment: "")
            return
        }
        setEnabled(true)
    }

    public func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "floatcutSyncEnabled")
        recordDiagnostic(enabled ? "sync_enable_requested" : "sync_disable_requested")
        if enabled {
            guard engine == nil else { return }
            do {
                let identity = try FloatcutSyncIdentityStore.shared.loadOrCreate()
                localDeviceID = identity.deviceID
                localCertificateSHA256 = identity.certificateSHA256
                let engine = FloatcutSyncEngine(identity: identity, coordinator: self)
                self.engine = engine
                statusText = NSLocalizedString("Starting local discovery…", comment: "")
                recordDiagnostic("sync_identity_ready")
                engine.start()
            } catch {
                recordDiagnostic("sync_identity_unavailable", ["error_type": String(describing: type(of: error))])
                statusText = error.localizedDescription
                securityWarning = error.localizedDescription
                identityResetRecommended = error is FloatcutSyncIdentityError
                UserDefaults.standard.set(false, forKey: "floatcutSyncEnabled")
            }
        } else {
            engine?.stop()
            engine = nil
            discoveredPeers = []
            onlineDeviceIDs = []
            statusText = NSLocalizedString("Synchronisation is disabled.", comment: "")
            recordDiagnostic("sync_disabled")
        }
    }

    public func shutdown() {
        engine?.stop()
        engine = nil
    }

    public func sendAcceptedLocalText(_ text: String) {
        guard isEnabled, clipboardDelegate?.syncCoordinatorIsClipboardPaused(self) != true else { return }
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= FloatcutSyncProtocol.maximumClipboardBytes else { return }
        engine?.sendLocalText(text)
    }

    public func sendAcceptedLocalImage(_ data: Data, pasteboardType: String) {
        guard isEnabled, clipboardDelegate?.syncCoordinatorIsClipboardPaused(self) != true else { return }
        engine?.sendLocalImage(data, pasteboardType: pasteboardType)
    }

    func applyRemoteText(_ text: String, peer: FloatcutSyncPeer, clipID: String,
                         token: FloatcutSyncWorkToken, completion: @escaping (String) -> Void) {
        let started = FloatcutSyncDiagnostics.shared.startMeasurement()
        DispatchQueue.main.async {
            defer { FloatcutSyncDiagnostics.shared.recordElapsed("remote_text_ui_wait_and_apply", since: started) }
            guard self.canApplyRemoteClip(from: peer), token.isActive else { completion("skipped"); return }
            let result = self.clipboardDelegate?.syncCoordinator(
                self,
                didReceiveText: text,
                peerName: peer.name,
                peerDeviceID: peer.deviceID,
                clipID: clipID
            ) ?? "invalid"
            completion(["applied", "duplicate", "skipped", "unsupported", "invalid"].contains(result) ? result : "invalid")
        }
    }

    func applyRemoteImage(_ data: Data, contentType: String, peer: FloatcutSyncPeer, clipID: String,
                          token: FloatcutSyncWorkToken, transferToken: FloatcutSyncWorkToken,
                          completion: @escaping (String) -> Void) {
        let started = FloatcutSyncDiagnostics.shared.startMeasurement()
        DispatchQueue.main.async {
            defer { FloatcutSyncDiagnostics.shared.recordElapsed("remote_image_ui_wait_and_apply", since: started) }
            guard self.canApplyRemoteClip(from: peer), token.isActive, transferToken.isActive else {
                completion("skipped"); return
            }
            let result = self.clipboardDelegate?.syncCoordinator(
                self, didReceiveImage: data, contentType: contentType, peerName: peer.name,
                peerDeviceID: peer.deviceID, clipID: clipID
            ) ?? "invalid"
            completion(["applied", "duplicate", "skipped", "unsupported", "invalid"].contains(result) ? result : "invalid")
        }
    }

    private func canApplyRemoteClip(from peer: FloatcutSyncPeer) -> Bool {
        guard isEnabled, clipboardDelegate?.syncCoordinatorIsClipboardPaused(self) != true,
              let current = pairedPeer(peer.deviceID), current.enabled, !current.identityMismatch,
              current.certificateSHA256 == peer.certificateSHA256 else { return false }
        return true
    }

    func checkRemoteClipAcceptance(from peer: FloatcutSyncPeer, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { completion(self.canApplyRemoteClip(from: peer)) }
    }

    func updateDiscovery(_ peers: [FloatcutDiscoveredPeer]) {
        recordDiagnostic("discovery_updated", ["peer_count": String(peers.count)])
        DispatchQueue.main.async {
            self.discoveredPeers = peers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.statusText = String(format: NSLocalizedString("%d device(s) available in the local network.", comment: ""), peers.count)
        }
    }

    func updateOnline(_ ids: Set<String>) {
        DispatchQueue.main.async { self.onlineDeviceIDs = ids }
    }

    func showNetworkError(_ detail: String) {
        recordDiagnostic("network_status", ["detail": detail])
        DispatchQueue.main.async { self.statusText = detail }
    }

    func reportIdentityMismatch(deviceID: String, name: String) {
        if var peer = pairedPeer(deviceID) {
            peer.identityMismatch = true
            try? upsertPeer(peer)
        }
        DispatchQueue.main.async {
            self.securityWarning = String(format: NSLocalizedString("The cryptographic identity of %@ has changed. Clipboard access was blocked. Remove and pair the device again.", comment: ""), name)
            self.identityResetRecommended = false
        }
        logger.error("peer_identity_mismatch peer=\(deviceID.prefix(8), privacy: .public)")
    }

    public func clearSecurityWarning() {
        securityWarning = nil
        identityResetRecommended = false
    }

    public func pair(deviceID: String) {
        guard pairedPeers.count < FloatcutSyncProtocol.maximumPeers else {
            statusText = NSLocalizedString("The limit of ten paired devices has been reached.", comment: "")
            return
        }
        guard let discovered = discoveredPeers.first(where: { $0.deviceID == deviceID }),
              discovered.protocolVersion == FloatcutSyncProtocol.version,
              discovered.capabilities == FloatcutSyncProtocol.capabilities,
              discovered.allowsPairing
        else {
            statusText = NSLocalizedString("This device is not currently available for pairing.", comment: "")
            return
        }
        guard let engine else {
            statusText = NSLocalizedString("Synchronisation is disabled.", comment: "")
            return
        }
        statusText = String(
            format: NSLocalizedString("Connecting to %@ for pairing…", comment: ""),
            discovered.name
        )
        recordDiagnostic("pair_requested", ["peer": String(deviceID.prefix(8))])
        engine.beginPairing(with: discovered)
    }

    public func unpair(deviceID: String) {
        guard let peer = pairedPeer(deviceID) else { return }
        let revocation = FloatcutSyncRevocation(
            peerDeviceID: peer.deviceID,
            certificateSHA256: peer.certificateSHA256,
            revocationID: FloatcutSyncProtocol.uuidV4(),
            revokedAtMS: Self.nowMS,
            acknowledged: false
        )
        do {
            try revocationStore.mutate { records in
                records.removeAll { $0.peerDeviceID == peer.deviceID }
                records.append(revocation)
            }
            try peerStore.mutate { $0.removeAll { $0.deviceID == peer.deviceID } }
            try pendingStore.mutate { $0.removeAll { $0.peerDeviceID == peer.deviceID } }
            refreshStores()
            engine?.refreshAdvertisement()
            engine?.deliverRevocation(revocation)
        } catch {
            statusText = error.localizedDescription
        }
    }

    public func setPeerEnabled(deviceID: String, enabled: Bool) {
        guard var peer = pairedPeer(deviceID) else { return }
        peer.enabled = enabled
        try? upsertPeer(peer)
        engine?.peerActivationChanged(deviceID: deviceID)
    }

    public func setOutgoingImagesAllowed(deviceID: String, allowed: Bool) {
        guard var peer = pairedPeer(deviceID) else { return }
        peer.allowsOutgoingImages = allowed
        do {
            try upsertPeer(peer)
            recordDiagnostic("v2_image_peer_setting_changed", [
                "peer": String(deviceID.prefix(8)), "allowed": allowed ? "true" : "false",
            ])
            if !allowed { engine?.outgoingImagesDisabled(deviceID: deviceID) }
        } catch {
            statusText = error.localizedDescription
            refreshStores()
        }
    }

    public func clearRevocations() {
        let recordCount = revocationStore.read().count
        do {
            try revocationStore.replace([])
            refreshStores()
            recordDiagnostic("revocation_list_cleared", ["record_count": String(recordCount)])
        } catch {
            statusText = error.localizedDescription
        }
    }

    public func resetIdentity() {
        UserDefaults.standard.set(false, forKey: "floatcutSyncEnabled")
        engine?.stopAndWait()
        engine = nil
        do {
            try FloatcutSyncIdentityStore.shared.reset()
            try peerStore.replace([])
            try pendingStore.replace([])
            try revocationStore.replace([])
            try legacyPeerStore.replace([])
            try legacyPendingStore.replace([])
            try legacyRevocationStore.replace([])
            localDeviceID = ""
            localCertificateSHA256 = ""
            refreshStores()
            securityWarning = nil
            identityResetRecommended = false
            statusText = NSLocalizedString("The sync identity was reset. All devices must be paired again.", comment: "")
        } catch {
            statusText = error.localizedDescription
            securityWarning = error.localizedDescription
            identityResetRecommended = error is FloatcutSyncIdentityError
        }
    }

    func pairedPeer(_ deviceID: String) -> FloatcutSyncPeer? {
        peerStore.read().first { $0.deviceID == deviceID }
    }

    func pairedPeerCount() -> Int { peerStore.read().count }

    func revocation(for deviceID: String) -> FloatcutSyncRevocation? {
        revocationStore.read().first { $0.peerDeviceID == deviceID }
    }

    func pendingPairing(peerDeviceID: String) -> FloatcutSyncPendingPairing? {
        pendingStore.read().first { $0.peerDeviceID == peerDeviceID && $0.expiresAtMS > Self.nowMS }
    }

    func savePending(_ pending: FloatcutSyncPendingPairing) throws {
        try pendingStore.mutate { records in
            records.removeAll { $0.peerDeviceID == pending.peerDeviceID || $0.requestID == pending.requestID }
            records.append(pending)
        }
    }

    func markPeerSeen(deviceID: String, name: String, platform: String, capabilities: [String]) -> FloatcutSyncPeer? {
        var updated: FloatcutSyncPeer?
        do {
            try peerStore.mutate { records in
                guard let index = records.firstIndex(where: { $0.deviceID == deviceID }) else { return }
                records[index].name = FloatcutSyncProtocol.truncateDeviceName(name)
                records[index].platform = platform
                records[index].capabilities = capabilities
                records[index].lastSeenMS = Self.nowMS
                updated = records[index]
            }
            refreshStores()
        } catch {
            logger.error("peer_last_seen_store_failed peer=\(deviceID.prefix(8), privacy: .public)")
        }
        return updated
    }

    func completePairing(peer: FloatcutSyncPeer, requestID: String) throws {
        guard pendingStore.read().contains(where: { $0.requestID == requestID && $0.peerDeviceID == peer.deviceID }) else {
            throw FloatcutSyncProtocolError.invalidState
        }
        try peerStore.mutate { records in
            guard records.contains(where: { $0.deviceID == peer.deviceID }) || records.count < FloatcutSyncProtocol.maximumPeers else {
                throw FloatcutSyncProtocolError.invalidState
            }
            records.removeAll { $0.deviceID == peer.deviceID }
            records.append(peer)
        }
        // Keep the completed handshake for up to ten minutes. If PAIR_COMPLETE is
        // lost, both sides can prove and resume the same transcript after reconnect.
        try revocationStore.mutate { $0.removeAll { $0.peerDeviceID == peer.deviceID } }
        refreshStores()
        engine?.refreshAdvertisement()
    }

    func acceptRemoteRevocation(_ revocation: FloatcutSyncRevocation) {
        try? peerStore.mutate { $0.removeAll { $0.deviceID == revocation.peerDeviceID } }
        try? pendingStore.mutate { $0.removeAll { $0.peerDeviceID == revocation.peerDeviceID } }
        var remote = revocation
        remote.acknowledged = true
        try? revocationStore.mutate { records in
            records.removeAll { $0.peerDeviceID == revocation.peerDeviceID }
            records.append(remote)
        }
        refreshStores()
    }

    func acknowledgeRevocation(_ revocationID: String) {
        try? revocationStore.mutate { records in
            guard let index = records.firstIndex(where: { $0.revocationID == revocationID }) else { return }
            records[index].acknowledged = true
        }
        refreshStores()
    }

    func confirmIncomingPairing(peerName: String, completion: @escaping (Bool) -> Void) {
        recordDiagnostic("pair_request_received")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Pair clipboard device?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@ wants to pair with Floatcut. No clipboard data is shared until the verification code is confirmed on both devices.", comment: ""), peerName)
            alert.addButton(withTitle: NSLocalizedString("Allow", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Reject", comment: ""))
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func confirmComparisonCode(_ code: String, peerName: String, completion: @escaping (Bool) -> Void) {
        recordDiagnostic("pair_code_presented")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Verification code: %@", comment: ""), code)
            alert.informativeText = String(format: NSLocalizedString("Confirm only if the same code is displayed on %@.", comment: ""), peerName)
            alert.addButton(withTitle: NSLocalizedString("Codes match", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func upsertPeer(_ peer: FloatcutSyncPeer) throws {
        try peerStore.mutate { records in
            records.removeAll { $0.deviceID == peer.deviceID }
            records.append(peer)
        }
        refreshStores()
    }

    private func refreshStores() {
        let peers = peerStore.read().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let revocations = revocationStore.read().sorted { $0.revokedAtMS > $1.revokedAtMS }
        DispatchQueue.main.async {
            self.pairedPeers = peers
            self.revocations = revocations
        }
    }

    private func purgeExpiredPendingPairings() {
        try? pendingStore.mutate { records in records.removeAll { $0.expiresAtMS <= Self.nowMS } }
    }

    private func repairCompletedPendingPairings() {
        let peers = Dictionary(uniqueKeysWithValues: peerStore.read().map { ($0.deviceID, $0) })
        try? pendingStore.mutate { records in
            for index in records.indices {
                guard let peer = peers[records[index].peerDeviceID],
                      peer.certificateSHA256 == records[index].peerCertificateSHA256
                else { continue }
                // A peer record is committed only after both confirmations.
                // Repair records written by older builds before that terminal
                // state was mirrored back into the pending store.
                records[index].localConfirmed = true
                records[index].remoteConfirmed = true
                records[index].complete = true
            }
        }
    }

    private func showV2RepairingNoticeIfNeeded() {
        guard peerStore.read().isEmpty, !legacyPeerStore.read().isEmpty,
              !UserDefaults.standard.bool(forKey: "floatcutSyncV2RepairingNoticeShown") else { return }
        UserDefaults.standard.set(true, forKey: "floatcutSyncV2RepairingNoticeShown")
        statusText = NSLocalizedString("Floatcut Sync now uses protocol v2. Previously paired devices must be confirmed once again. The local sync identity is preserved.", comment: "")
    }

    func recordDiagnostic(_ event: String, _ fields: [String: String] = [:]) {
        FloatcutSyncDiagnostics.shared.record(event, fields: fields)
    }

    static var nowMS: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

private final class FloatcutSyncEngine {
    private let identity: FloatcutSyncIdentity
    private weak var coordinator: FloatcutSyncCoordinator?
    private let queue = DispatchQueue(label: "de.meierkarsten.floatcut.sync.network", qos: .utility)
    private let handshakeRegistry = FloatcutTLSHandshakeRegistry()
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var discovered: [String: FloatcutDiscoveredPeer] = [:]
    private var connectionsByID: [UUID: FloatcutPeerConnection] = [:]
    private var connectionsByDeviceID: [String: FloatcutPeerConnection] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var incomingAttempts: [String: [Date]] = [:]
    private var stopped = false

    init(identity: FloatcutSyncIdentity, coordinator: FloatcutSyncCoordinator) {
        self.identity = identity
        self.coordinator = coordinator
    }

    func start() {
        queue.async {
            self.stopped = false
            self.cleanupStaleImageFiles()
            do {
                try self.startListener()
                self.startBrowser()
            } catch {
                self.coordinator?.showNetworkError(error.localizedDescription)
            }
        }
    }

    private func cleanupStaleImageFiles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("de.meierkarsten.floatcut-sync-v2", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["partial", "validated"].contains(file.pathExtension) { try? FileManager.default.removeItem(at: file) }
        coordinator?.recordDiagnostic("v2_image_receive_cleanup", ["stale_files": String(files.count)])
    }

    func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    func stopAndWait() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        stopped = true
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        connectionsByID.values.forEach { $0.cancel() }
        connectionsByID.removeAll()
        connectionsByDeviceID.removeAll()
        publishOnline()
    }

    func refreshAdvertisement() {
        queue.async {
            guard !self.stopped else { return }
            self.listener?.service = self.makeService()
        }
    }

    func beginPairing(with peer: FloatcutDiscoveredPeer) {
        queue.async {
            guard self.connectionsByDeviceID[peer.deviceID] == nil else {
                FloatcutSyncDiagnostics.shared.record("pair_request_blocked_active_connection", fields: ["peer": String(peer.deviceID.prefix(8))])
                self.coordinator?.showNetworkError(
                    String(format: NSLocalizedString("A connection to %@ is already active.", comment: ""), peer.name)
                )
                return
            }
            FloatcutSyncDiagnostics.shared.record("pair_connection_opening", fields: ["peer": String(peer.deviceID.prefix(8))])
            self.open(endpoint: peer.endpoint, direction: .outgoingPairing)
        }
    }

    func peerActivationChanged(deviceID: String) {
        queue.async {
            if self.coordinator?.pairedPeer(deviceID)?.enabled != true {
                self.connectionsByDeviceID[deviceID]?.cancel()
            } else if let peer = self.discovered[deviceID] {
                self.connectIfRequired(peer)
            }
        }
    }

    func sendLocalText(_ text: String) {
        queue.async {
            let data = Data(text.utf8)
            let clipID = FloatcutSyncProtocol.uuidV4()
            let fields: [String: Any] = [
                "clip_id": clipID,
                "source_device_id": self.identity.deviceID,
                "created_at_ms": FloatcutSyncCoordinator.nowMS,
                "content_type": FloatcutSyncProtocol.contentType,
                "utf8_size": data.count,
                "content_sha256": FloatcutSyncProtocol.sha256Hex(data),
                "hop_count": 0,
                "content": text,
            ]
            let message = FloatcutSyncWireMessage(type: "CLIPBOARD_UPDATE", fields: fields)
            // Deliberately no queue: this snapshot is the complete set of online trusted peers.
            for connection in self.connectionsByDeviceID.values where connection.isTrusted && connection.peer?.enabled == true {
                connection.send(message)
            }
        }
    }

    func sendLocalImage(_ data: Data, pasteboardType: String) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let recipients = self.connectionsByDeviceID.values.compactMap { connection -> (FloatcutPeerConnection, FloatcutSyncWorkToken)? in
                guard connection.isTrusted, let id = connection.peerDeviceID,
                      let peer = self.coordinator?.pairedPeer(id), peer.enabled, peer.allowsOutgoingImages,
                      let token = connection.reserveImagePreparation() else { return nil }
                return (connection, token)
            }
            guard !recipients.isEmpty else {
                self.coordinator?.recordDiagnostic("v2_image_preparation_skipped_no_recipients")
                return
            }
            FloatcutSyncImageWork.preparation.addOperation { [weak self] in
                let started = FloatcutSyncDiagnostics.shared.startMeasurement()
                let image = autoreleasepool { () -> (data: Data, contentType: String)? in
                    guard recipients.contains(where: { $0.1.isActive }),
                          let image = Self.normalizedImage(data, pasteboardType: pasteboardType),
                          image.data.count <= FloatcutSyncProtocol.maximumImageBytes else { return nil }
                    return image
                }
                let contentSHA256 = image.map { FloatcutSyncProtocol.sha256Hex($0.data) }
                FloatcutSyncDiagnostics.shared.recordElapsed("v2_image_prepare_and_hash", since: started,
                    fields: ["bytes": String(image?.data.count ?? 0), "recipients": String(recipients.count)])
                guard let self else { return }
                self.queue.async {
                    let clipID = FloatcutSyncProtocol.uuidV4()
                    for (connection, token) in recipients {
                        let reserved = connection.consumeImagePreparation(token)
                        guard reserved, !self.stopped, let image, let contentSHA256, let id = connection.peerDeviceID,
                              self.connectionsByDeviceID[id] === connection,
                              let peer = self.coordinator?.pairedPeer(id), peer.enabled, peer.allowsOutgoingImages else { continue }
                        connection.beginImageSend(data: image.data, contentType: image.contentType,
                                                  contentSHA256: contentSHA256, clipID: clipID)
                    }
                }
            }
        }
    }

    func outgoingImagesDisabled(deviceID: String) {
        queue.async { self.connectionsByDeviceID[deviceID]?.cancelOutgoingImage() }
    }

    private static func normalizedImage(_ data: Data, pasteboardType: String) -> (data: Data, contentType: String)? {
        if data.starts(with: FloatcutSyncProtocol.pngSignature) { return (data, "image/png") }
        if data.starts(with: FloatcutSyncProtocol.jpegSignature) { return (data, "image/jpeg") }
        guard let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.starts(with: FloatcutSyncProtocol.pngSignature) else { return nil }
        return (png, "image/png")
    }

    func deliverRevocation(_ revocation: FloatcutSyncRevocation) {
        queue.async {
            if let connection = self.connectionsByDeviceID[revocation.peerDeviceID] {
                connection.sendUnpair(revocation)
            } else if let discovered = self.discovered[revocation.peerDeviceID] {
                self.open(endpoint: discovered.endpoint, direction: .outgoingRevocation, expectedFingerprint: revocation.certificateSHA256)
            }
        }
    }

    private func startListener() throws {
        let parameters = makeTLSParameters()
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = makeService()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.coordinator?.recordDiagnostic("listener_failed", ["detail": error.localizedDescription])
                self?.coordinator?.showNetworkError(error.localizedDescription)
            case .ready: break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                guard let self else { return }
                guard self.allowIncoming(connection.endpoint) else { connection.cancel(); return }
                self.adopt(connection, direction: .incoming)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func makeService() -> NWListener.Service {
        let shortID = String(identity.deviceID.prefix(8))
        let baseName = FloatcutSyncProtocol.truncateUTF8(coordinator?.deviceName ?? "Floatcut", maximumBytes: 48, fallback: "Floatcut")
        let name = "\(baseName) – \(shortID)"
        let pair = FloatcutSyncPairingPolicy.advertisementValue(
            allowsNewPairings: coordinator?.allowsNewPairingRequests ?? true,
            pairedPeerCount: coordinator?.pairedPeerCount() ?? 0
        )
        let txt = NWTXTRecord([
            "id": identity.deviceID,
            "pv": String(FloatcutSyncProtocol.version),
            "platform": "macos",
            "caps": FloatcutSyncProtocol.capabilities.joined(separator: ","),
            "pair": pair,
        ])
        return NWListener.Service(name: name, type: FloatcutSyncProtocol.serviceType, domain: nil, txtRecord: txt)
    }

    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: FloatcutSyncProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state {
                self?.coordinator?.showNetworkError(String(format: NSLocalizedString("Local network access is waiting: %@", comment: ""), error.localizedDescription))
            } else if case .failed(let error) = state {
                self?.coordinator?.showNetworkError(error.localizedDescription)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var newPeers: [String: FloatcutDiscoveredPeer] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata,
                  let values = Self.normalizedTXTValues(txt),
                  let deviceID = values["id"], FloatcutSyncProtocol.isCanonicalUUID(deviceID), deviceID != identity.deviceID,
                  let pvString = values["pv"], let pv = Int(pvString),
                  let platform = values["platform"], FloatcutSyncProtocol.isPlatformIdentifier(platform),
                  let caps = values["caps"]?.split(separator: ",").map(String.init),
                  let pair = values["pair"], pair == "0" || pair == "1"
            else { continue }
            newPeers[deviceID] = FloatcutDiscoveredPeer(
                deviceID: deviceID,
                name: FloatcutSyncProtocol.truncateDeviceName(name),
                platform: platform,
                protocolVersion: pv,
                capabilities: caps,
                allowsPairing: pair == "1",
                endpoint: result.endpoint
            )
        }
        discovered = newPeers
        coordinator?.recordDiagnostic("bonjour_results", ["compatible_peer_count": String(newPeers.count)])
        coordinator?.updateDiscovery(Array(newPeers.values))
        for peer in newPeers.values { connectIfRequired(peer) }
    }

    private static func normalizedTXTValues(_ record: NWTXTRecord) -> [String: String]? {
        var values: [String: String] = [:]
        for (key, entry) in record {
            guard key.unicodeScalars.allSatisfy({ $0.isASCII }),
                  case .string(let value) = entry else { return nil }
            let normalized = key.lowercased()
            guard values[normalized] == nil else { return nil }
            values[normalized] = value
        }
        return values
    }

    private func connectIfRequired(_ discoveredPeer: FloatcutDiscoveredPeer) {
        if let pending = coordinator?.pendingPairing(peerDeviceID: discoveredPeer.deviceID),
           pending.localIsInitiator ?? (identity.deviceID < discoveredPeer.deviceID) {
            guard connectionsByDeviceID[discoveredPeer.deviceID] == nil else { return }
            open(endpoint: discoveredPeer.endpoint, direction: .outgoingPairing, expectedFingerprint: pending.peerCertificateSHA256)
            return
        }
        if let revocation = coordinator?.revocation(for: discoveredPeer.deviceID), !revocation.acknowledged {
            guard connectionsByDeviceID[discoveredPeer.deviceID] == nil else { return }
            open(endpoint: discoveredPeer.endpoint, direction: .outgoingRevocation, expectedFingerprint: revocation.certificateSHA256)
            return
        }
        guard discoveredPeer.protocolVersion == FloatcutSyncProtocol.version,
              discoveredPeer.capabilities == FloatcutSyncProtocol.capabilities,
              let peer = coordinator?.pairedPeer(discoveredPeer.deviceID), peer.enabled,
              identity.deviceID < peer.deviceID,
              connectionsByDeviceID[peer.deviceID] == nil
        else { return }
        open(endpoint: discoveredPeer.endpoint, direction: .outgoingTrusted, expectedFingerprint: peer.certificateSHA256)
    }

    private func open(endpoint: NWEndpoint, direction: FloatcutConnectionDirection, expectedFingerprint: String? = nil) {
        coordinator?.recordDiagnostic("connection_opening", ["direction": direction.diagnosticName])
        adopt(NWConnection(to: endpoint, using: makeTLSParameters(expectedFingerprint: expectedFingerprint)), direction: direction)
    }

    private func adopt(_ nwConnection: NWConnection, direction: FloatcutConnectionDirection) {
        let connection = FloatcutPeerConnection(
            connection: nwConnection,
            direction: direction,
            identity: identity,
            registry: handshakeRegistry,
            engine: self,
            coordinator: coordinator,
            queue: queue
        )
        connectionsByID[connection.id] = connection
        connection.start()
    }

    fileprivate func didIdentify(_ connection: FloatcutPeerConnection, deviceID: String) -> Bool {
        guard connectionsByDeviceID[deviceID] == nil else {
            coordinator?.recordDiagnostic("connection_rejected_duplicate", ["peer": String(deviceID.prefix(8))])
            return false
        }
        connectionsByDeviceID[deviceID] = connection
        coordinator?.recordDiagnostic("peer_identified", ["peer": String(deviceID.prefix(8)), "direction": connection.directionName])
        publishOnline()
        return true
    }

    fileprivate func didBecomeTrusted(_ connection: FloatcutPeerConnection) {
        reconnectAttempts[connection.peerDeviceID ?? ""] = 0
        if let name = connection.peer?.name {
            coordinator?.showNetworkError(
                String(format: NSLocalizedString("Connected to %@.", comment: ""), name)
            )
        }
        coordinator?.recordDiagnostic("pairing_trusted", ["peer": String((connection.peerDeviceID ?? "").prefix(8))])
        publishOnline()
    }

    fileprivate func newPairingRejectionReason(_ connection: FloatcutPeerConnection) -> String? {
        FloatcutSyncPairingPolicy.rejectionReason(
            allowsNewPairings: coordinator?.allowsNewPairingRequests ?? true,
            pairedPeerCount: coordinator?.pairedPeerCount() ?? 0,
            concurrentPairingCount: connectionsByID.values.filter { $0 !== connection && $0.isPairing }.count
        )
    }

    fileprivate func connectionEnded(_ connection: FloatcutPeerConnection) {
        coordinator?.recordDiagnostic("connection_ended", ["peer": String((connection.peerDeviceID ?? "unknown").prefix(8)), "direction": connection.directionName])
        connectionsByID.removeValue(forKey: connection.id)
        if let deviceID = connection.peerDeviceID, connectionsByDeviceID[deviceID] === connection {
            connectionsByDeviceID.removeValue(forKey: deviceID)
            scheduleReconnect(deviceID: deviceID)
        }
        publishOnline()
    }

    private func scheduleReconnect(deviceID: String) {
        guard !stopped, discovered[deviceID] != nil,
              coordinator?.pairedPeer(deviceID)?.enabled == true,
              identity.deviceID < deviceID
        else { return }
        let attempt = min((reconnectAttempts[deviceID] ?? 0) + 1, 6)
        reconnectAttempts[deviceID] = attempt
        let base = min(pow(2.0, Double(attempt - 1)), 30)
        let delay = min(30, base * Double.random(in: 0.8...1.2))
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.connectionsByDeviceID[deviceID] == nil, let peer = self.discovered[deviceID] else { return }
            self.connectIfRequired(peer)
        }
    }

    private func publishOnline() {
        let ids = Set(connectionsByDeviceID.compactMap { $0.value.isTrusted ? $0.key : nil })
        coordinator?.updateOnline(ids)
    }

    private func allowIncoming(_ endpoint: NWEndpoint) -> Bool {
        let key: String
        if case .hostPort(let host, _) = endpoint { key = host.debugDescription }
        else { key = endpoint.debugDescription }
        let cutoff = Date().addingTimeInterval(-60)
        var attempts = (incomingAttempts[key] ?? []).filter { $0 >= cutoff }
        guard attempts.count < 5 else { return false }
        attempts.append(Date())
        incomingAttempts[key] = attempts
        return true
    }

    private func makeTLSParameters(expectedFingerprint: String? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)
        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        let registry = handshakeRegistry
        weak var coordinator = coordinator
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = chain.first,
                  let deviceID = FloatcutTLSHandshakeRegistry.deviceID(from: certificate),
                  FloatcutSyncCertificateValidator.validate(certificate: certificate, expectedDeviceID: deviceID)
            else {
                complete(false)
                return
            }
            let fingerprint = FloatcutSyncProtocol.sha256Hex(SecCertificateCopyData(certificate) as Data)
            let knownPeer = coordinator?.pairedPeer(deviceID)
            guard (expectedFingerprint == nil || fingerprint == expectedFingerprint),
                  (knownPeer == nil || knownPeer?.certificateSHA256 == fingerprint),
                  registry.record(certificate: certificate, deviceID: deviceID)
            else {
                if let knownPeer { coordinator?.reportIdentityMismatch(deviceID: deviceID, name: knownPeer.name) }
                complete(false)
                return
            }
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

private enum FloatcutConnectionDirection {
    case incoming
    case outgoingPairing
    case outgoingTrusted
    case outgoingRevocation

    var isOutgoing: Bool {
        switch self {
        case .incoming: return false
        default: return true
        }
    }

    var diagnosticName: String {
        switch self {
        case .incoming: return "incoming"
        case .outgoingPairing: return "outgoing_pairing"
        case .outgoingTrusted: return "outgoing_trusted"
        case .outgoingRevocation: return "outgoing_revocation"
        }
    }
}

private final class FloatcutSyncDiagnostics {
    static let shared = FloatcutSyncDiagnostics()

    private let enabledKey = "floatcutSyncDiagnosticLoggingEnabled"
    private let queue = DispatchQueue(label: "de.meierkarsten.floatcut.sync.diagnostics")
    private let iso8601 = ISO8601DateFormatter()
    let logFileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.meierkarsten.floatcut", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logFileURL = base.appendingPathComponent("diagnostics.log")
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    func startMeasurement() -> UInt64 {
        isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    func recordElapsed(_ event: String, since start: UInt64, fields: [String: String] = [:]) {
        guard start > 0 else { return }
        var values = fields
        values["elapsed_ms"] = String(format: "%.3f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        record(event, fields: values)
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }
        queue.async {
            var payload = fields
            payload["timestamp"] = self.iso8601.string(from: Date())
            payload["event"] = event
            guard let line = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + Data([0x0A]) else { return }
            self.trimIfNeeded()
            if !FileManager.default.fileExists(atPath: self.logFileURL.path) {
                FileManager.default.createFile(atPath: self.logFileURL.path, contents: line)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: self.logFileURL) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    private func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 1_048_576,
              let data = try? Data(contentsOf: logFileURL)
        else { return }
        try? data.suffix(524_288).write(to: logFileURL, options: .atomic)
    }
}

private struct FloatcutTLSPeerContext {
    let deviceID: String
    let certificate: SecCertificate
    let certificateDER: Data
    let certificateSHA256: String
    let publicKeyData: Data
    let recordedAt: Date
}

private final class FloatcutTLSHandshakeRegistry {
    private let lock = NSLock()
    private var contexts: [String: FloatcutTLSPeerContext] = [:]

    func record(certificate: SecCertificate, deviceID: String) -> Bool {
        guard let publicKeyData = FloatcutSyncCertificateValidator.subjectPublicKeyInfo(certificate: certificate)
        else { return false }
        let der = SecCertificateCopyData(certificate) as Data
        let context = FloatcutTLSPeerContext(
            deviceID: deviceID,
            certificate: certificate,
            certificateDER: der,
            certificateSHA256: FloatcutSyncProtocol.sha256Hex(der),
            publicKeyData: publicKeyData,
            recordedAt: Date()
        )
        lock.lock()
        contexts[context.certificateSHA256] = context
        contexts = contexts.filter { Date().timeIntervalSince($0.value.recordedAt) < 120 }
        lock.unlock()
        return true
    }

    func context(fingerprint: String, publicKeyData: Data?) -> FloatcutTLSPeerContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let context = contexts[fingerprint], Date().timeIntervalSince(context.recordedAt) < 120 else { return nil }
        if let publicKeyData, publicKeyData != context.publicKeyData { return nil }
        return context
    }

    static func deviceID(from certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        let prefix = Data("urn:floatcut:device:".utf8)
        guard let range = der.range(of: prefix), range.upperBound + 36 <= der.count else { return nil }
        let bytes = der.subdata(in: range.upperBound..<(range.upperBound + 36))
        guard let value = String(data: bytes, encoding: .ascii), FloatcutSyncProtocol.isCanonicalUUID(value) else { return nil }
        return value
    }
}

private enum FloatcutPeerConnectionState {
    case awaitingHello
    case pairing
    case trusted
    case closing
}

private struct FloatcutOutgoingImageTransfer {
    let clipID: String
    let contentType: String
    let data: Data
    let contentSHA256: String
    let chunkCount: Int
    var waitingForReady = true
    let startedAt = FloatcutSyncDiagnostics.shared.startMeasurement()
}

private final class FloatcutPeerConnection {
    let id = UUID()
    private let connection: NWConnection
    private let direction: FloatcutConnectionDirection
    private let identity: FloatcutSyncIdentity
    private let registry: FloatcutTLSHandshakeRegistry
    private unowned let engine: FloatcutSyncEngine
    private weak var coordinator: FloatcutSyncCoordinator?
    private let queue: DispatchQueue
    private var decoder = FloatcutSyncFrameDecoder()
    private var state: FloatcutPeerConnectionState = .awaitingHello
    private var didSendHello = false
    private var didReceiveHello = false
    private var ended = false
    private var lastReceived = Date()
    private var lastSent = Date()
    private var keepaliveTimer: DispatchSourceTimer?
    private var replay = FloatcutReplayCache()
    private var tlsContext: FloatcutTLSPeerContext?
    private(set) var peerDeviceID: String?
    private(set) var peer: FloatcutSyncPeer?
    private var peerName = "Device"
    private var peerPlatform = "unknown"
    private var peerCapabilities: [String] = []
    private var pairing: FloatcutPairingSession?
    private var incomingImage: FloatcutIncomingImageFile?
    private var incomingImageToken: FloatcutSyncWorkToken?
    private var incomingImageClipID: String?
    private var abortedIncomingClips = FloatcutReplayCache()
    private let lifetimeToken = FloatcutSyncWorkToken()
    private let clipboardInbox = FloatcutSyncOrderedInbox()
    private var receiveInFlight = false
    private var handlingRead = false
    private var receivedEOF = false
    private var outgoingImage: FloatcutOutgoingImageTransfer?
    private let imagePreparation = FloatcutSyncImagePreparation()
    private var imageTimeoutGeneration = 0
    private var incomingImageTimer: DispatchSourceTimer?

    var isTrusted: Bool { state == .trusted }
    var isPairing: Bool { state == .pairing }
    var directionName: String { direction.diagnosticName }

    init(
        connection: NWConnection,
        direction: FloatcutConnectionDirection,
        identity: FloatcutSyncIdentity,
        registry: FloatcutTLSHandshakeRegistry,
        engine: FloatcutSyncEngine,
        coordinator: FloatcutSyncCoordinator?,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.direction = direction
        self.identity = identity
        self.registry = registry
        self.engine = engine
        self.coordinator = coordinator
        self.queue = queue
    }

    func start() {
        clipboardInbox.didProgress = { [weak self] in self?.receiveNext() }
        connection.stateUpdateHandler = { [weak self] state in self?.handleConnectionState(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.ended, self.state == .awaitingHello else { return }
            self.coordinator?.recordDiagnostic(
                "connection_establishment_timed_out",
                ["direction": self.direction.diagnosticName]
            )
            if self.direction == .outgoingPairing {
                self.coordinator?.showNetworkError(
                    NSLocalizedString("The pairing connection timed out. Please try again.", comment: "")
                )
            }
            self.cancel()
        }
    }

    func cancel() {
        guard !ended else { return }
        imagePreparation.cancel()
        lifetimeToken.cancel()
        clipboardInbox.discard()
        cleanupIncomingImage(event: "v2_image_receive_cleanup")
        outgoingImage = nil
        imageTimeoutGeneration += 1
        state = .closing
        connection.cancel()
    }

    func send(_ message: FloatcutSyncWireMessage, completion: (() -> Void)? = nil) {
        guard state != .closing else { return }
        if (message.type == "CLIPBOARD_UPDATE" || message.type.hasPrefix("CLIPBOARD_IMAGE_")), state != .trusted { return }
        do {
            let started = FloatcutSyncDiagnostics.shared.startMeasurement()
            let data = try FloatcutSyncCodec.encode(message)
            FloatcutSyncDiagnostics.shared.recordElapsed("wire_encode", since: started,
                fields: ["type": message.type, "bytes": String(data.count)])
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.cancel() } else {
                    self.lastSent = Date()
                    completion?()
                }
            })
        } catch {
            // A text can satisfy the 512 KiB UTF-8 limit yet exceed the 1 MiB
            // frame limit after mandatory JSON escaping. It is simply not part
            // of this online fan-out snapshot; never tear down a healthy peer.
            if message.type == "CLIPBOARD_UPDATE" { return }
            if message.type == "ERROR" { cancel(); return }
            sendError(code: "invalid_json", detail: "Local encoding failed", replyTo: message.messageID, close: true)
        }
    }

    func sendUnpair(_ revocation: FloatcutSyncRevocation) {
        lifetimeToken.cancel()
        clipboardInbox.discard()
        cleanupIncomingImage(event: "v2_image_receive_cleanup")
        send(FloatcutSyncWireMessage(type: "UNPAIR", fields: [
            "revocation_id": revocation.revocationID,
            "revoked_at_ms": revocation.revokedAtMS,
            "reason": "user_request",
        ]))
    }

    func reserveImagePreparation() -> FloatcutSyncWorkToken? {
        guard state == .trusted, outgoingImage == nil else { return nil }
        return imagePreparation.reserve()
    }

    func consumeImagePreparation(_ token: FloatcutSyncWorkToken) -> Bool {
        imagePreparation.consume(token)
    }

    func beginImageSend(data: Data, contentType: String, contentSHA256: String, clipID: String) {
        guard state == .trusted, outgoingImage == nil,
              coordinator?.pairedPeer(peerDeviceID ?? "")?.allowsOutgoingImages == true,
              FloatcutSyncProtocol.imageContentTypes.contains(contentType),
              !data.isEmpty, data.count <= FloatcutSyncProtocol.maximumImageBytes else { return }
        let count = (data.count + FloatcutSyncProtocol.imageChunkBytes - 1) / FloatcutSyncProtocol.imageChunkBytes
        let transfer = FloatcutOutgoingImageTransfer(
            clipID: clipID, contentType: contentType, data: data,
            contentSHA256: contentSHA256, chunkCount: count
        )
        outgoingImage = transfer
        coordinator?.recordDiagnostic("v2_image_begin_sent", ["peer": String((peerDeviceID ?? "unknown").prefix(8)), "bytes": String(data.count), "type": contentType])
        send(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_BEGIN", fields: [
            "clip_id": clipID, "source_device_id": identity.deviceID,
            "created_at_ms": FloatcutSyncCoordinator.nowMS, "content_type": contentType,
            "byte_size": data.count, "content_sha256": transfer.contentSHA256,
            "chunk_size": FloatcutSyncProtocol.imageChunkBytes, "chunk_count": count, "hop_count": 0,
        ]))
        armImageTimeout(seconds: 15, clipID: clipID)
    }

    func cancelOutgoingImage() {
        imagePreparation.cancel()
        guard let transfer = outgoingImage else { return }
        send(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_ABORT", fields: [
            "clip_id": transfer.clipID, "reason": "sender_cancelled",
        ]))
        coordinator?.recordDiagnostic("v2_image_send_aborted", ["peer": String((peerDeviceID ?? "unknown").prefix(8)), "reason": "sender_cancelled"])
        outgoingImage = nil
        imageTimeoutGeneration += 1
    }

    private func handleConnectionState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            coordinator?.recordDiagnostic("connection_ready", ["direction": direction.diagnosticName])
            guard captureTLSContext() else { cancel(); return }
            sendHello()
            receiveNext()
            startKeepalive()
        case .failed(let error):
            coordinator?.recordDiagnostic("connection_failed", ["direction": direction.diagnosticName, "detail": error.localizedDescription])
            finish()
        case .waiting(let error):
            coordinator?.recordDiagnostic("connection_waiting", ["direction": direction.diagnosticName, "detail": error.localizedDescription])
        case .preparing:
            coordinator?.recordDiagnostic("connection_preparing", ["direction": direction.diagnosticName])
        case .cancelled:
            coordinator?.recordDiagnostic("connection_cancelled", ["direction": direction.diagnosticName])
            finish()
        default: break
        }
    }

    private func captureTLSContext() -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let raw = sec_protocol_metadata_copy_peer_public_key(metadata.securityProtocolMetadata)
        let publicData: Data?
        if let raw {
            var result = Data()
            (raw as DispatchData).enumerateBytes { buffer, _, _ in
                result.append(contentsOf: buffer)
            }
            publicData = result
        } else {
            publicData = nil
        }
        // HELLO supplies the fingerprint. Exact public-key association is completed there.
        tlsContext = nil
        pairing?.tlsPublicKeyData = publicData
        if pairing == nil { pairing = FloatcutPairingSession(tlsPublicKeyData: publicData) }
        return true
    }

    private func sendHello() {
        guard !didSendHello else { return }
        didSendHello = true
        let nonce = (try? FloatcutSyncProtocol.secureNonce()) ?? Data(repeating: 0, count: 32)
        send(FloatcutSyncWireMessage(type: "HELLO", fields: [
            "device_id": identity.deviceID,
            "device_name": coordinator?.deviceName ?? "Floatcut",
            "platform": "macos",
            "capabilities": FloatcutSyncProtocol.capabilities,
            "certificate_sha256": identity.certificateSHA256,
            "session_nonce": FloatcutSyncProtocol.base64URL(nonce),
        ]))
    }

    private func receiveNext() {
        guard !ended, state != .closing, !handlingRead, !receiveInFlight else { return }
        if receivedEOF {
            if clipboardInbox.isEmpty { cancel() }
            return
        }
        guard clipboardInbox.canReceive else { return }
        receiveInFlight = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.ended, self.state != .closing else { return }
            self.receiveInFlight = false
            self.handlingRead = true
            defer { self.handlingRead = false }
            self.receivedEOF = complete
            if error != nil { self.cancel(); return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                do {
                    let started = FloatcutSyncDiagnostics.shared.startMeasurement()
                    let messages = try self.decoder.append(data)
                    FloatcutSyncDiagnostics.shared.recordElapsed("wire_decode", since: started,
                        fields: ["bytes": String(data.count), "messages": String(messages.count)])
                    for message in messages {
                        if ["CLIPBOARD_UPDATE", "CLIPBOARD_IMAGE_BEGIN", "CLIPBOARD_IMAGE_CHUNK", "CLIPBOARD_IMAGE_COMMIT"].contains(message.type) {
                            self.clipboardInbox.enqueue(bytes: message.payloadByteCount) { [weak self] done in
                                guard let self, self.lifetimeToken.isActive else { done(); return }
                                if let clipID = try? message.string("clip_id"), self.abortedIncomingClips.contains(clipID) {
                                    done(); return
                                }
                                do { try self.handle(message, completion: done) }
                                catch let failure as FloatcutSyncProtocolError {
                                    self.handleProtocolError(failure)
                                    done()
                                } catch {
                                    self.cancel()
                                    done()
                                }
                            }
                        } else {
                            try self.handle(message)
                        }
                        if self.state == .closing { return }
                    }
                } catch let protocolError as FloatcutSyncProtocolError {
                    self.handleProtocolError(protocolError)
                    return
                } catch {
                    self.sendError(code: "invalid_json", detail: "Message validation failed", replyTo: nil, close: true)
                    return
                }
            }
            if complete {
                do {
                    try self.decoder.finish()
                } catch let protocolError as FloatcutSyncProtocolError {
                    self.handleProtocolError(protocolError)
                    return
                } catch {
                    self.cancel()
                    return
                }
            }
            self.handlingRead = false
            self.receiveNext()
        }
    }

    private func handle(_ message: FloatcutSyncWireMessage, completion: @escaping () -> Void = {}) throws {
        guard !replay.contains(message.messageID) else { completion(); return }
        replay.insert(message.messageID)
        if !didReceiveHello {
            guard message.type == "HELLO" else { throw FloatcutSyncProtocolError.invalidState }
            try handleHello(message)
            completion()
            return
        }
        switch message.type {
        case "HELLO": throw FloatcutSyncProtocolError.invalidState
        case "PAIR_REQUEST": try handlePairRequest(message)
        case "PAIR_CHALLENGE": try handlePairChallenge(message)
        case "PAIR_CONFIRM": try handlePairConfirm(message)
        case "PAIR_STATUS": try handlePairStatus(message)
        case "PAIR_COMPLETE": try handlePairComplete(message)
        case "PAIR_REJECT": cancel()
        case "CLIPBOARD_UPDATE":
            try handleClipboard(message, completion: completion)
            return
        case "CLIPBOARD_IMAGE_BEGIN":
            try handleImageBegin(message, completion: completion)
            return
        case "CLIPBOARD_IMAGE_CHUNK":
            try handleImageChunk(message, completion: completion)
            return
        case "CLIPBOARD_IMAGE_COMMIT":
            try handleImageCommit(message, completion: completion)
            return
        case "CLIPBOARD_IMAGE_ABORT": try handleImageAbort(message)
        case "CLIPBOARD_ACK": try handleClipboardACK(message)
        case "PING":
            send(FloatcutSyncWireMessage(type: "PONG", fields: ["reply_to": message.messageID]))
        case "PONG": break
        case "UNPAIR": try handleUnpair(message)
        case "UNPAIR_ACK":
            coordinator?.acknowledgeRevocation(try message.string("revocation_id"))
            cancel()
        case "ERROR": break
        default: throw FloatcutSyncProtocolError.unknownMessageType(message.type)
        }
        completion()
    }

    private func handleHello(_ message: FloatcutSyncWireMessage) throws {
        let deviceID = try message.string("device_id")
        let fingerprint = try message.string("certificate_sha256")
        guard deviceID != identity.deviceID,
              let context = registry.context(fingerprint: fingerprint, publicKeyData: pairing?.tlsPublicKeyData),
              context.deviceID == deviceID
        else { throw FloatcutSyncProtocolError.invalidField("HELLO identity") }
        tlsContext = context
        peerDeviceID = deviceID
        peerName = try message.string("device_name")
        peerPlatform = try message.string("platform")
        peerCapabilities = message.object["capabilities"] as? [String] ?? []
        didReceiveHello = true
        guard engine.didIdentify(self, deviceID: deviceID) else { cancel(); return }

        if let revocation = coordinator?.revocation(for: deviceID), revocation.certificateSHA256 == fingerprint, !revocation.acknowledged {
            state = .pairing
            sendUnpair(revocation)
            return
        }
        if let peer = coordinator?.pairedPeer(deviceID) {
            guard peer.certificateSHA256 == fingerprint else {
                coordinator?.reportIdentityMismatch(deviceID: deviceID, name: peerName)
                sendError(code: "identity_mismatch", detail: "Pinned certificate changed", replyTo: message.messageID, close: true)
                return
            }
            guard peer.enabled else { cancel(); return }
            if let pending = coordinator?.pendingPairing(peerDeviceID: deviceID),
               pending.peerCertificateSHA256 == fingerprint {
                self.peer = peer
                pairing = FloatcutPairingSession(pending: pending, tlsPublicKeyData: pairing?.tlsPublicKeyData)
                state = .pairing
                send(FloatcutSyncWireMessage(type: "PAIR_STATUS", fields: [
                    "request_id": pending.requestID,
                    "transcript_sha256": pending.transcriptSHA256,
                    "state": pending.complete ? "complete" : "confirmed",
                ]))
                return
            }
            let canonical = identity.deviceID < deviceID ? direction.isOutgoing : !direction.isOutgoing
            guard canonical || direction == .outgoingRevocation else { cancel(); return }
            self.peer = coordinator?.markPeerSeen(
                deviceID: peer.deviceID,
                name: peerName,
                platform: peerPlatform,
                capabilities: peerCapabilities
            ) ?? peer
            state = .trusted
            engine.didBecomeTrusted(self)
            return
        }
        state = .pairing
        if let pending = coordinator?.pendingPairing(peerDeviceID: deviceID), pending.peerCertificateSHA256 == fingerprint {
            pairing = FloatcutPairingSession(pending: pending, tlsPublicKeyData: pairing?.tlsPublicKeyData)
            send(FloatcutSyncWireMessage(type: "PAIR_STATUS", fields: [
                "request_id": pending.requestID,
                "transcript_sha256": pending.transcriptSHA256,
                "state": pending.complete ? "complete" : "confirmed",
            ]))
        } else if direction == .outgoingPairing {
            try initiatePairing()
        }
    }

    private func initiatePairing() throws {
        let nonce = try FloatcutSyncProtocol.secureNonce()
        let requestID = FloatcutSyncProtocol.uuidV4()
        pairing?.requestID = requestID
        pairing?.initiatorNonce = nonce
        pairing?.localIsInitiator = true
        armPairingTimeout(requestID: requestID)
        send(FloatcutSyncWireMessage(type: "PAIR_REQUEST", fields: [
            "request_id": requestID,
            "initiator_nonce": FloatcutSyncProtocol.base64URL(nonce),
        ]))
    }

    private func handlePairRequest(_ message: FloatcutSyncWireMessage) throws {
        coordinator?.recordDiagnostic("pair_request_received_wire")
        guard state == .pairing, direction == .incoming,
              pairing?.requestID == nil
        else {
            sendPairReject(message: message, reason: "invalid_request")
            return
        }
        if let reason = engine.newPairingRejectionReason(self) {
            coordinator?.recordDiagnostic("pair_request_rejected", [
                "peer": String((peerDeviceID ?? "unknown").prefix(8)),
                "reason": reason,
            ])
            sendPairReject(message: message, reason: reason)
            return
        }
        let requestID = try message.string("request_id")
        let nonce = try FloatcutSyncProtocol.decodeBase64URL(try message.string("initiator_nonce"), expectedBytes: 32)
        pairing?.requestID = requestID
        pairing?.initiatorNonce = nonce
        pairing?.localIsInitiator = false
        armPairingTimeout(requestID: requestID)
        coordinator?.confirmIncomingPairing(peerName: peerName) { [weak self] accepted in
            self?.queue.async {
                guard let self, self.state == .pairing else { return }
                guard accepted else { self.sendPairReject(requestID: requestID, reason: "user_rejected"); return }
                do {
                    let acceptorNonce = try FloatcutSyncProtocol.secureNonce()
                    self.pairing?.acceptorNonce = acceptorNonce
                    self.send(FloatcutSyncWireMessage(type: "PAIR_CHALLENGE", fields: [
                        "request_id": requestID,
                        "acceptor_nonce": FloatcutSyncProtocol.base64URL(acceptorNonce),
                    ]))
                    try self.presentPairingCode()
                } catch { self.sendPairReject(requestID: requestID, reason: "invalid_request") }
            }
        }
    }

    private func handlePairChallenge(_ message: FloatcutSyncWireMessage) throws {
        coordinator?.recordDiagnostic("pair_challenge_received")
        guard state == .pairing, pairing?.localIsInitiator == true,
              try message.string("request_id") == pairing?.requestID
        else { throw FloatcutSyncProtocolError.invalidState }
        pairing?.acceptorNonce = try FloatcutSyncProtocol.decodeBase64URL(try message.string("acceptor_nonce"), expectedBytes: 32)
        try presentPairingCode()
    }

    private func presentPairingCode() throws {
        guard let context = tlsContext, let session = pairing,
              let initiatorNonce = session.initiatorNonce,
              let acceptorNonce = session.acceptorNonce,
              let requestID = session.requestID,
              let peerDeviceID
        else { throw FloatcutSyncProtocolError.invalidState }
        let localIsInitiator = session.localIsInitiator
        let transcript = try FloatcutSyncProtocol.pairingTranscript(
            initiatorDeviceID: localIsInitiator ? identity.deviceID : peerDeviceID,
            initiatorCertificateSHA256: localIsInitiator ? identity.certificateSHA256 : context.certificateSHA256,
            initiatorNonce: initiatorNonce,
            acceptorDeviceID: localIsInitiator ? peerDeviceID : identity.deviceID,
            acceptorCertificateSHA256: localIsInitiator ? context.certificateSHA256 : identity.certificateSHA256,
            acceptorNonce: acceptorNonce
        )
        pairing?.transcriptSHA256 = transcript.sha256
        coordinator?.confirmComparisonCode(transcript.comparisonCode, peerName: peerName) { [weak self] confirmed in
            self?.queue.async {
                guard let self, self.state == .pairing else { return }
                guard confirmed else { self.sendPairReject(requestID: requestID, reason: "user_rejected"); return }
                do {
                    self.pairing?.localConfirmed = true
                    try self.persistPending()
                    self.send(FloatcutSyncWireMessage(type: "PAIR_CONFIRM", fields: [
                        "request_id": requestID,
                        "transcript_sha256": transcript.sha256,
                    ]))
                    try self.completePairingIfReady()
                } catch { self.sendPairReject(requestID: requestID, reason: "invalid_request") }
            }
        }
    }

    private func handlePairConfirm(_ message: FloatcutSyncWireMessage) throws {
        coordinator?.recordDiagnostic("pair_confirm_received")
        guard state == .pairing,
              try message.string("request_id") == pairing?.requestID,
              try message.string("transcript_sha256") == pairing?.transcriptSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        pairing?.remoteConfirmed = true
        try persistPending()
        try completePairingIfReady()
    }

    private func handlePairStatus(_ message: FloatcutSyncWireMessage) throws {
        coordinator?.recordDiagnostic("pair_status_received")
        guard state == .pairing, let pending = coordinator?.pendingPairing(peerDeviceID: peerDeviceID ?? ""),
              try message.string("request_id") == pending.requestID,
              try message.string("transcript_sha256") == pending.transcriptSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        pairing = FloatcutPairingSession(pending: pending, tlsPublicKeyData: pairing?.tlsPublicKeyData)
        if try message.string("state") == "complete" {
            pairing?.remoteConfirmed = true
            try persistPending()
            try completePairingIfReady()
        } else {
            pairing?.remoteConfirmed = true
            send(FloatcutSyncWireMessage(type: "PAIR_CONFIRM", fields: [
                "request_id": pending.requestID,
                "transcript_sha256": pending.transcriptSHA256,
            ]))
            try completePairingIfReady()
        }
    }

    private func handlePairComplete(_ message: FloatcutSyncWireMessage) throws {
        coordinator?.recordDiagnostic("pair_complete_received")
        let requestID = try message.string("request_id")
        let transcript = try message.string("transcript_sha256")

        // Both peers may complete at almost the same time. If our own
        // PAIR_CONFIRM already promoted the connection to Trusted, accept the
        // matching peer completion as an idempotent acknowledgement instead of
        // closing a successfully paired connection with invalid_state.
        if state == .trusted,
           requestID == pairing?.requestID,
           transcript == pairing?.transcriptSHA256 {
            return
        }

        guard state == .pairing,
              requestID == pairing?.requestID,
              transcript == pairing?.transcriptSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        pairing?.remoteConfirmed = true
        try persistPending()
        try completePairingIfReady(sendComplete: false)
    }

    private func persistPending() throws {
        guard let session = pairing, let context = tlsContext, let peerDeviceID,
              let requestID = session.requestID, let transcript = session.transcriptSHA256
        else { throw FloatcutSyncProtocolError.invalidState }
        try coordinator?.savePending(FloatcutSyncPendingPairing(
            requestID: requestID,
            peerDeviceID: peerDeviceID,
            peerCertificateSHA256: context.certificateSHA256,
            peerCertificateDERBase64: context.certificateDER.base64EncodedString(),
            transcriptSHA256: transcript,
            expiresAtMS: FloatcutSyncCoordinator.nowMS + 600_000,
            localIsInitiator: session.localIsInitiator,
            localConfirmed: session.localConfirmed,
            remoteConfirmed: session.remoteConfirmed,
            complete: session.localConfirmed && session.remoteConfirmed
        ))
    }

    private func completePairingIfReady(sendComplete: Bool = true) throws {
        guard let session = pairing, session.localConfirmed, session.remoteConfirmed,
              let requestID = session.requestID, let transcript = session.transcriptSHA256,
              let context = tlsContext, let peerDeviceID
        else { return }
        // Persist the terminal flags before the peer record. Reconnect must
        // never observe a trusted peer alongside an incomplete pending record.
        try persistPending()
        let peer = FloatcutSyncPeer(
            deviceID: peerDeviceID,
            name: peerName,
            platform: peerPlatform,
            certificateSHA256: context.certificateSHA256,
            certificateDERBase64: context.certificateDER.base64EncodedString(),
            pairedAtMS: FloatcutSyncCoordinator.nowMS,
            lastSeenMS: FloatcutSyncCoordinator.nowMS,
            capabilities: peerCapabilities,
            enabled: true,
            identityMismatch: false,
            allowsOutgoingImages: false
        )
        try coordinator?.completePairing(peer: peer, requestID: requestID)
        self.peer = peer
        pairing?.complete = true
        state = .trusted
        if sendComplete {
            send(FloatcutSyncWireMessage(type: "PAIR_COMPLETE", fields: [
                "request_id": requestID,
                "transcript_sha256": transcript,
            ]))
        }
        engine.didBecomeTrusted(self)
    }

    private func handleClipboard(_ message: FloatcutSyncWireMessage, completion: @escaping () -> Void) throws {
        guard state == .trusted, let peer, try message.string("source_device_id") == peer.deviceID else {
            throw FloatcutSyncProtocolError.invalidState
        }
        let clipID = try message.string("clip_id")
        guard !replay.contains(clipID) else {
            sendClipboardACK(clipID: clipID, status: "duplicate")
            completion()
            return
        }
        replay.insert(clipID)
        guard let coordinator else { completion(); return }
        coordinator.applyRemoteText(try message.string("content"), peer: peer, clipID: clipID, token: lifetimeToken) { [weak self] status in
            guard let self else { return }
            self.queue.async {
                if self.lifetimeToken.isActive { self.sendClipboardACK(clipID: clipID, status: status) }
                completion()
            }
        }
    }

    private func handleClipboardACK(_ message: FloatcutSyncWireMessage) throws {
        let clipID = try message.string("clip_id")
        let status = try message.string("status")
        guard var transfer = outgoingImage, transfer.clipID == clipID else { return }
        if status == "ready" {
            guard transfer.waitingForReady, coordinator?.pairedPeer(peerDeviceID ?? "")?.allowsOutgoingImages == true else { return }
            transfer.waitingForReady = false
            outgoingImage = transfer
            imageTimeoutGeneration += 1
            coordinator?.recordDiagnostic("v2_image_ready_received", ["peer": String((peerDeviceID ?? "unknown").prefix(8))])
            sendNextOutgoingImageChunk(index: 0)
        } else {
            outgoingImage = nil
            imageTimeoutGeneration += 1
            FloatcutSyncDiagnostics.shared.recordElapsed("v2_image_begin_to_final_ack", since: transfer.startedAt,
                fields: ["peer": String((peerDeviceID ?? "unknown").prefix(8)), "status": status])
            coordinator?.recordDiagnostic(status == "applied" ? "v2_image_send_completed" : "v2_image_send_aborted", [
                "peer": String((peerDeviceID ?? "unknown").prefix(8)), "status": status,
            ])
        }
    }

    private func handleImageBegin(_ message: FloatcutSyncWireMessage, completion: @escaping () -> Void) throws {
        guard state == .trusted, let peer,
              try message.string("source_device_id") == peer.deviceID else { throw FloatcutSyncProtocolError.invalidState }
        let clipID = try message.string("clip_id")
        guard incomingImageClipID == nil else { sendClipboardACK(clipID: clipID, status: "skipped"); completion(); return }
        guard !replay.contains(clipID) else { sendClipboardACK(clipID: clipID, status: "duplicate"); completion(); return }
        guard let coordinator else { sendClipboardACK(clipID: clipID, status: "invalid"); completion(); return }
        let token = FloatcutSyncWorkToken()
        incomingImageToken = token
        incomingImageClipID = clipID
        armIncomingImageTimeout(clipID: clipID)
        coordinator.checkRemoteClipAcceptance(from: peer) { [weak self] allowed in
            guard let self else { return }
            self.queue.async {
                guard self.lifetimeToken.isActive, token.isActive else { completion(); return }
                guard allowed else {
                    self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
                    self.sendClipboardACK(clipID: clipID, status: "skipped")
                    completion(); return
                }
                self.replay.insert(clipID)
                self.openIncomingImage(message, peer: peer, clipID: clipID, token: token, completion: completion)
            }
        }
    }

    private func openIncomingImage(_ message: FloatcutSyncWireMessage, peer: FloatcutSyncPeer,
                                   clipID: String, token: FloatcutSyncWorkToken, completion: @escaping () -> Void) {
        FloatcutSyncImageWork.queue.async { [weak self] in
            let result = Result { try FloatcutIncomingImageFile(message: message, token: token) }
            guard let self else {
                if case .success(let file) = result { file.cleanup() }
                return
            }
            self.queue.async {
                guard self.lifetimeToken.isActive, token.isActive else {
                    if case .success(let file) = result { FloatcutSyncImageWork.queue.async { file.cleanup() } }
                    completion(); return
                }
                switch result {
                case .success(let file):
                    self.incomingImage = file
                    self.coordinator?.recordDiagnostic("v2_image_begin_received", ["peer": String(peer.deviceID.prefix(8)), "bytes": String(file.byteSize)])
                    self.sendClipboardACK(clipID: clipID, status: "ready")
                case .failure:
                    self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
                    self.sendClipboardACK(clipID: clipID, status: "invalid")
                }
                completion()
            }
        }
    }

    private func handleImageChunk(_ message: FloatcutSyncWireMessage, completion: @escaping () -> Void) throws {
        guard let transfer = incomingImage,
              try message.string("clip_id") == transfer.clipID else {
            cleanupIncomingImage(event: "v2_image_receive_cleanup")
            throw FloatcutSyncProtocolError.invalidState
        }
        FloatcutSyncImageWork.queue.async { [weak self] in
            let result = Result { try transfer.append(message) }
            guard let self else { return }
            self.queue.async {
                guard self.lifetimeToken.isActive, transfer.token.isActive else { completion(); return }
                switch result {
                case .success:
                    self.armIncomingImageTimeout(clipID: transfer.clipID)
                    let index = Int((try? message.integer("chunk_index")) ?? 0) + 1
                    if index == 1 || index == transfer.chunkCount {
                        self.coordinator?.recordDiagnostic("v2_image_chunk_progress_received", ["peer": String((self.peerDeviceID ?? "unknown").prefix(8)), "chunk": String(index), "chunks": String(transfer.chunkCount)])
                    }
                case .failure(let error):
                    self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
                    if let failure = error as? FloatcutSyncProtocolError { self.handleProtocolError(failure) }
                    else {
                        // V2 reserves IMAGE_ABORT for the sender. A receiver
                        // that cannot persist a chunk terminates this connection.
                        self.sendError(code: "invalid_state", detail: "Local image storage failed",
                                       replyTo: message.messageID, close: true)
                    }
                }
                completion()
            }
        }
    }

    private func handleImageCommit(_ message: FloatcutSyncWireMessage, completion: @escaping () -> Void) throws {
        guard let transfer = incomingImage, try message.string("clip_id") == transfer.clipID else {
            throw FloatcutSyncProtocolError.invalidState
        }
        incomingImageTimer?.cancel()
        incomingImageTimer = nil
        FloatcutSyncImageWork.queue.async { [weak self] in
            let started = FloatcutSyncDiagnostics.shared.startMeasurement()
            let result = Result { try transfer.finish() }
            FloatcutSyncDiagnostics.shared.recordElapsed("v2_image_file_commit_validation", since: started,
                fields: ["bytes": String(transfer.byteSize)])
            guard let self else { transfer.cleanup(); return }
            self.queue.async {
                guard self.lifetimeToken.isActive, transfer.token.isActive else { completion(); return }
                guard case .success(let data) = result, let peer = self.peer, let coordinator = self.coordinator else {
                    self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
                    self.sendClipboardACK(clipID: transfer.clipID, status: "invalid")
                    completion(); return
                }
                coordinator.recordDiagnostic("v2_image_commit_validated", ["peer": String(peer.deviceID.prefix(8)), "bytes": String(data.count)])
                coordinator.applyRemoteImage(data, contentType: transfer.contentType, peer: peer, clipID: transfer.clipID,
                                             token: self.lifetimeToken, transferToken: transfer.token) { [weak self] status in
                    guard let self else { return }
                    self.queue.async {
                        if self.lifetimeToken.isActive, transfer.token.isActive {
                            self.sendClipboardACK(clipID: transfer.clipID, status: status)
                            coordinator.recordDiagnostic("v2_image_receive_completed", ["peer": String(peer.deviceID.prefix(8)), "status": status])
                            self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
                        }
                        completion()
                    }
                }
            }
        }
    }

    private func handleImageAbort(_ message: FloatcutSyncWireMessage) throws {
        let clipID = try message.string("clip_id")
        abortedIncomingClips.insert(clipID)
        guard incomingImageClipID == clipID else { return }
        cleanupIncomingImage(event: "v2_image_receive_cleanup")
    }

    private func cleanupIncomingImage(event: String) {
        incomingImageToken?.cancel()
        incomingImageToken = nil
        incomingImageClipID = nil
        if let transfer = incomingImage { FloatcutSyncImageWork.queue.async { transfer.cleanup() } }
        incomingImage = nil
        incomingImageTimer?.cancel()
        incomingImageTimer = nil
        coordinator?.recordDiagnostic(event, ["peer": String((peerDeviceID ?? "unknown").prefix(8))])
    }

    private func armImageTimeout(seconds: TimeInterval, clipID: String) {
        imageTimeoutGeneration += 1
        let generation = imageTimeoutGeneration
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.imageTimeoutGeneration == generation,
                  self.outgoingImage?.clipID == clipID else { return }
            self.send(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_ABORT", fields: ["clip_id": clipID, "reason": "timeout"]))
            self.outgoingImage = nil
            self.imageTimeoutGeneration += 1
            self.coordinator?.recordDiagnostic("v2_image_send_aborted", ["peer": String((self.peerDeviceID ?? "unknown").prefix(8)), "reason": "timeout"])
        }
    }

    private func sendNextOutgoingImageChunk(index: Int) {
        guard let transfer = outgoingImage, !transfer.waitingForReady,
              coordinator?.pairedPeer(peerDeviceID ?? "")?.allowsOutgoingImages == true else { return }
        if index >= transfer.chunkCount {
            send(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_COMMIT", fields: ["clip_id": transfer.clipID])) { [weak self] in
                guard let self, self.outgoingImage?.clipID == transfer.clipID else { return }
                self.coordinator?.recordDiagnostic("v2_image_commit_sent", ["peer": String((self.peerDeviceID ?? "unknown").prefix(8))])
                self.armImageTimeout(seconds: 30, clipID: transfer.clipID)
            }
            return
        }
        let start = index * FloatcutSyncProtocol.imageChunkBytes
        let end = min(start + FloatcutSyncProtocol.imageChunkBytes, transfer.data.count)
        let chunk = transfer.data.subdata(in: start..<end)
        send(FloatcutSyncWireMessage(type: "CLIPBOARD_IMAGE_CHUNK", fields: [
            "clip_id": transfer.clipID, "chunk_index": index, "data_size": chunk.count,
            "data_sha256": FloatcutSyncProtocol.sha256Hex(chunk), "data": FloatcutSyncProtocol.base64URL(chunk),
        ])) { [weak self] in
            guard let self, self.outgoingImage?.clipID == transfer.clipID else { return }
            if index == 0 || index == transfer.chunkCount - 1 || (index * 4 / max(transfer.chunkCount, 1)) != ((index - 1) * 4 / max(transfer.chunkCount, 1)) {
                self.coordinator?.recordDiagnostic("v2_image_chunk_progress", ["peer": String((self.peerDeviceID ?? "unknown").prefix(8)), "chunk": String(index + 1), "chunks": String(transfer.chunkCount)])
            }
            self.sendNextOutgoingImageChunk(index: index + 1)
        }
    }

    private func armIncomingImageTimeout(clipID: String) {
        if incomingImageTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, self.incomingImageClipID == clipID else { return }
                self.abortedIncomingClips.insert(clipID)
                self.cleanupIncomingImage(event: "v2_image_receive_cleanup")
            }
            incomingImageTimer = timer
            timer.schedule(deadline: .now() + 30)
            timer.resume()
        } else {
            incomingImageTimer?.schedule(deadline: .now() + 30)
        }
    }

    private func handleUnpair(_ message: FloatcutSyncWireMessage) throws {
        guard let peerDeviceID, let context = tlsContext else { throw FloatcutSyncProtocolError.invalidState }
        let revocationID = try message.string("revocation_id")
        let revocation = FloatcutSyncRevocation(
            peerDeviceID: peerDeviceID,
            certificateSHA256: context.certificateSHA256,
            revocationID: revocationID,
            revokedAtMS: try message.integer("revoked_at_ms"),
            acknowledged: true
        )
        lifetimeToken.cancel()
        clipboardInbox.discard()
        cleanupIncomingImage(event: "v2_image_receive_cleanup")
        coordinator?.acceptRemoteRevocation(revocation)
        send(FloatcutSyncWireMessage(type: "UNPAIR_ACK", fields: ["revocation_id": revocationID]))
        queue.asyncAfter(deadline: .now() + 0.2) { self.cancel() }
    }

    private func sendClipboardACK(clipID: String, status: String) {
        send(FloatcutSyncWireMessage(type: "CLIPBOARD_ACK", fields: ["clip_id": clipID, "status": status]))
    }

    private func sendPairReject(message: FloatcutSyncWireMessage, reason: String) {
        let requestID = (try? message.string("request_id")) ?? FloatcutSyncProtocol.uuidV4()
        sendPairReject(requestID: requestID, reason: reason)
    }

    private func sendPairReject(requestID: String, reason: String) {
        send(FloatcutSyncWireMessage(type: "PAIR_REJECT", fields: ["request_id": requestID, "reason": reason]))
        queue.asyncAfter(deadline: .now() + 0.2) { self.cancel() }
    }

    private func armPairingTimeout(requestID: String) {
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.state == .pairing, self.pairing?.requestID == requestID else { return }
            self.sendPairReject(requestID: requestID, reason: "timeout")
        }
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) >= 90 {
                self.cancel()
            } else if Date().timeIntervalSince(self.lastSent) >= 30 {
                self.send(FloatcutSyncWireMessage(type: "PING", fields: ["sent_at_ms": FloatcutSyncCoordinator.nowMS]))
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func handleProtocolError(_ error: FloatcutSyncProtocolError) {
        let code: String
        switch error {
        case .invalidFrameLength: code = "invalid_frame"
        case .invalidUTF8, .invalidJSON, .duplicateJSONKey, .nestingTooDeep, .nonIntegerJSONNumber: code = "invalid_json"
        case .incompatibleVersion: code = "incompatible_version"
        case .unknownMessageType: code = "unknown_message_type"
        case .payloadTooLarge: code = "payload_too_large"
        case .hashMismatch: code = "hash_mismatch"
        case .invalidState: code = "invalid_state"
        default: code = "invalid_json"
        }
        let close = code != "unknown_message_type"
        sendError(code: code, detail: error.localizedDescription, replyTo: nil, close: close)
    }

    private func sendError(code: String, detail: String, replyTo: String?, close: Bool) {
        var fields: [String: Any] = ["code": code, "detail": String(detail.prefix(160))]
        if let replyTo { fields["reply_to"] = replyTo }
        send(FloatcutSyncWireMessage(type: "ERROR", fields: fields))
        if close {
            lifetimeToken.cancel()
            clipboardInbox.discard()
            cleanupIncomingImage(event: "v2_image_receive_cleanup")
            state = .closing
            queue.asyncAfter(deadline: .now() + 0.1) { self.cancel() }
        }
    }

    private func finish() {
        guard !ended else { return }
        imagePreparation.cancel()
        lifetimeToken.cancel()
        clipboardInbox.discard()
        cleanupIncomingImage(event: "v2_image_receive_cleanup")
        outgoingImage = nil
        imageTimeoutGeneration += 1
        state = .closing
        ended = true
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        engine.connectionEnded(self)
    }
}

private final class FloatcutPairingSession {
    var tlsPublicKeyData: Data?
    var requestID: String?
    var initiatorNonce: Data?
    var acceptorNonce: Data?
    var transcriptSHA256: String?
    var localIsInitiator = false
    var localConfirmed = false
    var remoteConfirmed = false
    var complete = false

    init(tlsPublicKeyData: Data?) {
        self.tlsPublicKeyData = tlsPublicKeyData
    }

    init(pending: FloatcutSyncPendingPairing, tlsPublicKeyData: Data?) {
        self.tlsPublicKeyData = tlsPublicKeyData
        requestID = pending.requestID
        transcriptSHA256 = pending.transcriptSHA256
        localIsInitiator = pending.localIsInitiator ?? false
        localConfirmed = pending.localConfirmed
        remoteConfirmed = pending.remoteConfirmed
        complete = pending.complete
    }
}

private struct FloatcutReplayCache {
    private var entries: [(String, Date)] = []

    mutating func contains(_ id: String) -> Bool {
        purge()
        return entries.contains { $0.0 == id }
    }

    mutating func insert(_ id: String) {
        purge()
        guard !entries.contains(where: { $0.0 == id }) else { return }
        entries.append((id, Date()))
        if entries.count > 2_048 { entries.removeFirst(entries.count - 2_048) }
    }

    private mutating func purge() {
        let cutoff = Date().addingTimeInterval(-600)
        entries.removeAll { $0.1 < cutoff }
    }
}
