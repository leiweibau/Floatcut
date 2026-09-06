import Foundation
import Network
import Security

private func parameters(identity: FloatcutSyncIdentity, expectedPeer: FloatcutSyncIdentity, queue: DispatchQueue) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_peer_authentication_required(options, true)
    guard let localIdentity = sec_identity_create(identity.identity) else { fatalError("sec_identity_create failed") }
    sec_protocol_options_set_local_identity(options, localIdentity)
    sec_protocol_options_set_verify_block(options, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let certificate = chain.first,
              FloatcutSyncProtocol.sha256Hex(SecCertificateCopyData(certificate) as Data) == expectedPeer.certificateSHA256,
              FloatcutSyncCertificateValidator.validate(certificate: certificate, expectedDeviceID: expectedPeer.deviceID)
        else { complete(false); return }
        complete(true)
    }, queue)
    return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
}

private func peerPublicKeyData(_ connection: NWConnection) -> Data? {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
          let raw = sec_protocol_metadata_copy_peer_public_key(metadata.securityProtocolMetadata)
    else { return nil }
    var result = Data()
    (raw as DispatchData).enumerateBytes { buffer, _, _ in result.append(contentsOf: buffer) }
    return result
}

let suffix = UUID().uuidString.lowercased()
let suiteA = "de.meierkarsten.floatcut.sync-tls-test.a.\(suffix)"
let suiteB = "de.meierkarsten.floatcut.sync-tls-test.b.\(suffix)"
let defaultsA = UserDefaults(suiteName: suiteA)!
let defaultsB = UserDefaults(suiteName: suiteB)!
let storeA = FloatcutSyncIdentityStore(defaults: defaultsA, keyTag: Data("\(suiteA).key".utf8), certificateLabel: "Floatcut Sync TLS Test A \(suffix)")
let storeB = FloatcutSyncIdentityStore(defaults: defaultsB, keyTag: Data("\(suiteB).key".utf8), certificateLabel: "Floatcut Sync TLS Test B \(suffix)")
let queue = DispatchQueue(label: "de.meierkarsten.floatcut.sync-tls-test")
let ready = DispatchSemaphore(value: 0)
var listener: NWListener?
var client: NWConnection?
var server: NWConnection?
var failure: String?

do {
    let identityA = try storeA.loadOrCreate()
    let identityB = try storeB.loadOrCreate()
    listener = try NWListener(using: parameters(identity: identityA, expectedPeer: identityB, queue: queue), on: .any)
    listener?.newConnectionHandler = { connection in
        server = connection
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                if let metadataKey = peerPublicKeyData(connection), metadataKey != identityB.publicKeyData {
                    failure = "server TLS public-key metadata mismatch (metadata \(metadataKey.count)/\(FloatcutSyncProtocol.sha256Hex(metadataKey)), certificate \(identityB.publicKeyData.count)/\(FloatcutSyncProtocol.sha256Hex(identityB.publicKeyData)))"
                }
                ready.signal()
            }
            if case .failed(let error) = state { failure = "server: \(error)"; ready.signal() }
        }
        connection.start(queue: queue)
    }
    listener?.stateUpdateHandler = { state in
        switch state {
        case .ready:
            guard let port = listener?.port else { failure = "listener has no port"; ready.signal(); return }
            let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters(identity: identityB, expectedPeer: identityA, queue: queue))
            client = connection
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    if let metadataKey = peerPublicKeyData(connection), metadataKey != identityA.publicKeyData {
                        failure = "client TLS public-key metadata mismatch (metadata \(metadataKey.count)/\(FloatcutSyncProtocol.sha256Hex(metadataKey)), certificate \(identityA.publicKeyData.count)/\(FloatcutSyncProtocol.sha256Hex(identityA.publicKeyData)))"
                    }
                    ready.signal()
                }
                if case .failed(let error) = state { failure = "client: \(error)"; ready.signal() }
            }
            connection.start(queue: queue)
        case .failed(let error): failure = "listener: \(error)"; ready.signal()
        default: break
        }
    }
    listener?.start(queue: queue)

    guard ready.wait(timeout: .now() + 10) == .success,
          ready.wait(timeout: .now() + 10) == .success,
          failure == nil
    else { fatalError("Mutual TLS 1.3 handshake failed: \(failure ?? "timeout")") }

    client?.cancel()
    server?.cancel()
    listener?.cancel()
    try storeA.reset()
    try storeB.reset()
    defaultsA.removePersistentDomain(forName: suiteA)
    defaultsB.removePersistentDomain(forName: suiteB)
    print("Floatcut sync mutual TLS 1.3 tests passed")
} catch {
    client?.cancel()
    server?.cancel()
    listener?.cancel()
    try? storeA.reset()
    try? storeB.reset()
    defaultsA.removePersistentDomain(forName: suiteA)
    defaultsB.removePersistentDomain(forName: suiteB)
    fatalError("TLS test failed: \(error)")
}
