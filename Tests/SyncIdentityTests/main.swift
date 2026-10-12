import Foundation
import Security

private struct TestDERNode {
    var tag: UInt8
    var body: Data
    var encoded: Data {
        var size = body.count
        var length = [UInt8]()
        repeat { length.insert(UInt8(size & 255), at: 0); size >>= 8 } while size > 0
        let prefix: Data = body.count < 128 ? Data([UInt8(body.count)]) : Data([0x80 | UInt8(length.count)] + length)
        return Data([tag]) + prefix + body
    }
}

private func testDERNodes(_ data: Data) -> [TestDERNode] {
    let bytes = Array(data)
    var index = 0
    var result: [TestDERNode] = []
    while index < bytes.count {
        let tag = bytes[index]; index += 1
        var count = Int(bytes[index]); index += 1
        if count & 0x80 != 0 {
            let octets = count & 0x7f; count = 0
            for _ in 0..<octets { count = count << 8 | Int(bytes[index]); index += 1 }
        }
        result.append(TestDERNode(tag: tag, body: Data(bytes[index..<index + count])))
        index += count
    }
    return result
}

private func alterExtensions(_ tbs: inout [TestDERNode], _ mutate: (inout [TestDERNode]) -> Void) {
    let sequence = testDERNodes(tbs[7].body)[0]
    var extensions = testDERNodes(sequence.body)
    mutate(&extensions)
    tbs[7].body = TestDERNode(tag: 0x30, body: extensions.reduce(Data()) { $0 + $1.encoded }).encoded
}

/// Re-sign malformed profiles with the valid identity key: rejection must be
/// caused by profile validation rather than merely a broken self-signature.
private func alteredCertificate(_ identity: FloatcutSyncIdentity, _ mutate: (inout [TestDERNode]) -> Void) throws -> SecCertificate {
    var root = testDERNodes(testDERNodes(identity.certificateDER)[0].body)
    var tbs = testDERNodes(root[0].body)
    mutate(&tbs)
    root[0].body = tbs.reduce(Data()) { $0 + $1.encoded }
    guard let signature = SecKeyCreateSignature(identity.privateKey, .ecdsaSignatureMessageX962SHA256,
                                                root[0].encoded as CFData, nil) as Data?
    else { fatalError("Could not sign malformed test certificate") }
    root[2].body = Data([0]) + signature
    let der = TestDERNode(tag: 0x30, body: root.reduce(Data()) { $0 + $1.encoded }).encoded
    guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { fatalError("Invalid DER test construction") }
    return certificate
}

private func persistenceStore(suiteName: String) -> (UserDefaults, FloatcutSyncIdentityStore) {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create persistence-test defaults suite")
    }
    return (
        defaults,
        FloatcutSyncIdentityStore(
            defaults: defaults,
            keyTag: Data("\(suiteName).key".utf8),
            certificateLabel: "Floatcut Sync Restart Test \(suiteName)"
        )
    )
}

if CommandLine.arguments.count == 3 {
    let mode = CommandLine.arguments[1]
    let suiteName = CommandLine.arguments[2]
    let (persistenceDefaults, persistenceStore) = persistenceStore(suiteName: suiteName)
    switch mode {
    case "--persistence-create":
        do {
            let identity = try persistenceStore.loadOrCreate()
            print("Created restart-test identity \(identity.deviceID)")
            exit(0)
        } catch {
            fatalError("Could not create restart-test identity: \(error)")
        }
    case "--persistence-reload":
        do {
            guard let expectedDeviceID = persistenceDefaults.string(forKey: "floatcutSyncDeviceID"),
                  let expectedDER = persistenceDefaults.data(forKey: "floatcutSyncIdentityCertificateDER")
            else { fatalError("Restart-test identity was not persisted") }
            let identity = try persistenceStore.loadOrCreate()
            guard identity.deviceID == expectedDeviceID,
                  identity.certificateSHA256 == FloatcutSyncProtocol.sha256Hex(expectedDER)
            else { fatalError("Restart-test identity changed across processes") }
            print("Reloaded restart-test identity \(identity.deviceID)")
            exit(0)
        } catch {
            fatalError("Could not reload restart-test identity: \(error)")
        }
    case "--persistence-cleanup":
        try? persistenceStore.reset()
        persistenceDefaults.removePersistentDomain(forName: suiteName)
        exit(0)
    default:
        fatalError("Unknown identity-test mode")
    }
}

let legacyPeerJSON = Data("""
[{"deviceID":"00112233-4455-4677-8899-aabbccddeeff","name":"Legacy fixture","platform":"macos","certificateSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","certificateDERBase64":"AA==","pairedAtMS":1,"lastSeenMS":1,"capabilities":["clip.image.jpeg","clip.image.png","clip.text.utf8"],"enabled":true,"identityMismatch":false}]
""".utf8)
let peerWithoutImageSetting = try JSONDecoder().decode([FloatcutSyncPeer].self, from: legacyPeerJSON)[0]
guard peerWithoutImageSetting.allowsOutgoingImages == false, peerWithoutImageSetting.trustGeneration == 0 else {
    fatalError("A peer without allowsOutgoingImages did not fail closed")
}
var peerWithImageSetting = peerWithoutImageSetting
peerWithImageSetting.allowsOutgoingImages = true
peerWithImageSetting.trustGeneration = 42
let peerRoundTrip = try JSONDecoder().decode([FloatcutSyncPeer].self, from: JSONEncoder().encode([peerWithImageSetting]))[0]
guard peerRoundTrip.allowsOutgoingImages, peerRoundTrip.enabled,
      peerRoundTrip.trustGeneration == 42,
      peerRoundTrip.certificateSHA256 == peerWithoutImageSetting.certificateSHA256 else {
    fatalError("The per-peer image setting did not persist independently")
}

let suffix = UUID().uuidString.lowercased()
let suiteName = "de.meierkarsten.floatcut.sync-identity-test.\(suffix)"
let keyTag = Data("\(suiteName).key".utf8)
let certificateLabel = "Floatcut Sync Identity Test \(suffix)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    fatalError("Could not create isolated defaults suite")
}
let store = FloatcutSyncIdentityStore(
    defaults: defaults,
    keyTag: keyTag,
    certificateLabel: certificateLabel
)

do {
    let first = try store.loadOrCreate()
    let second = try store.loadOrCreate()
    guard first.deviceID == second.deviceID,
          first.certificateSHA256 == second.certificateSHA256,
          first.certificateDER == second.certificateDER,
          FloatcutSyncCertificateValidator.validate(certificate: first.certificate, expectedDeviceID: first.deviceID)
    else { fatalError("Identity was not stable or certificate validation failed") }

    let malformedProfiles: [(String, (inout [TestDERNode]) -> Void)] = [
        ("noncritical BasicConstraints", { tbs in alterExtensions(&tbs) { extensions in
            var parts = testDERNodes(extensions[0].body); parts.remove(at: 1)
            extensions[0].body = parts.reduce(Data()) { $0 + $1.encoded }
        }}),
        ("noncritical KeyUsage", { tbs in alterExtensions(&tbs) { extensions in
            var parts = testDERNodes(extensions[1].body); parts.remove(at: 1)
            extensions[1].body = parts.reduce(Data()) { $0 + $1.encoded }
        }}),
        ("CA=true", { tbs in alterExtensions(&tbs) { extensions in
            var parts = testDERNodes(extensions[0].body)
            parts[2].body = Data([0x30, 3, 1, 1, 0xff])
            extensions[0].body = parts.reduce(Data()) { $0 + $1.encoded }
        }}),
        ("extra SAN URI", { tbs in alterExtensions(&tbs) { extensions in
            var parts = testDERNodes(extensions[3].body)
            let san = testDERNodes(parts[1].body)[0]
            parts[1].body = TestDERNode(tag: 0x30, body: san.body + san.body).encoded
            extensions[3].body = parts.reduce(Data()) { $0 + $1.encoded }
        }}),
        ("duplicate EKU", { tbs in alterExtensions(&tbs) { extensions in
            var parts = testDERNodes(extensions[2].body)
            let eku = testDERNodes(parts[1].body)[0]
            parts[1].body = TestDERNode(tag: 0x30, body: eku.body + testDERNodes(eku.body)[0].encoded).encoded
            extensions[2].body = parts.reduce(Data()) { $0 + $1.encoded }
        }}),
        ("duplicate extension", { tbs in alterExtensions(&tbs) { extensions in extensions.append(extensions[0]) }}),
        ("unknown critical extension", { tbs in alterExtensions(&tbs) { extensions in
            extensions.append(TestDERNode(tag: 0x30, body: Data([6, 2, 42, 3, 1, 1, 0xff, 4, 2, 5, 0])))
        }}),
        ("zero serial", { $0[1].body = Data([0]) }),
        ("160-bit serial", { $0[1].body = Data([0]) + Data(repeating: 0xff, count: 20) }),
    ]
    for (name, mutate) in malformedProfiles {
        let certificate = try alteredCertificate(first, mutate)
        guard !FloatcutSyncCertificateValidator.validate(certificate: certificate, expectedDeviceID: first.deviceID)
        else { fatalError("Malformed certificate accepted: \(name)") }
    }
    let unknownNoncritical = try alteredCertificate(first) { tbs in alterExtensions(&tbs) { extensions in
        extensions.append(TestDERNode(tag: 0x30, body: Data([6, 2, 42, 3, 4, 2, 5, 0])))
    }}
    guard FloatcutSyncCertificateValidator.validate(certificate: unknownNoncritical, expectedDeviceID: first.deviceID)
    else { fatalError("Unknown noncritical extension was not ignored") }

    let originalBinding = String(repeating: "a", count: 64)
    let originalTranscript = String(repeating: "b", count: 64)
    var pending = FloatcutSyncPendingPairing(requestID: FloatcutSyncProtocol.uuidV4(), peerDeviceID: first.deviceID,
        peerCertificateSHA256: first.certificateSHA256, peerCertificateDERBase64: first.certificateDER.base64EncodedString(),
        transcriptSHA256: originalTranscript, expiresAtMS: 0, localIsInitiator: true,
        localConfirmed: false, remoteConfirmed: true, complete: false,
        bootDeadline: FloatcutSyncBootDeadline.starting(durationMS: 120_000), originalControlBindingSHA256: originalBinding,
        initiatorDeviceID: FloatcutSyncProtocol.uuidV4(), initiatorCertificateSHA256: String(repeating: "c", count: 64),
        acceptorDeviceID: first.deviceID, acceptorCertificateSHA256: first.certificateSHA256,
        initiatorCommitmentSHA256: String(repeating: "d", count: 64), acceptorCommitmentSHA256: String(repeating: "e", count: 64),
        trustGeneration: 42)
    guard pending.isValidSameBoot() else { fatalError("Valid same-boot pending record rejected") }
    let restoredPending = try JSONDecoder().decode(FloatcutSyncPendingPairing.self, from: JSONEncoder().encode(pending))
    let resumed = try FloatcutSyncPairingV3(pending: restoredPending)
    guard resumed.originalControlBindingSHA256 == originalBinding, resumed.transcript?.sha256 == originalTranscript,
          resumed.phase == .revealed, !resumed.localConfirmed, resumed.remoteConfirmed,
          resumed.deadline == pending.bootDeadline else { fatalError("Resume replaced original context or local confirmation") }
    _ = try resumed.confirmLocal()
    try resumed.markCompleted()
    pending.complete = true
    pending.localConfirmed = true
    pending.bootDeadline = resumed.deadline
    let completedPending = try JSONDecoder().decode(FloatcutSyncPendingPairing.self, from: JSONEncoder().encode(pending))
    guard completedPending.isValidSameBoot() else { fatalError("Valid completed retention rejected") }
    let completed = try FloatcutSyncPairingV3(pending: completedPending)
    try completed.markCompleted()
    guard completed.phase == .complete, completed.deadline == resumed.deadline else { fatalError("Completed replay renewed retention") }
    pending.localConfirmed = false
    guard !pending.isValidSameBoot() else { fatalError("Completed record without both confirmations was trusted") }
    pending = restoredPending
    pending.bootDeadline = nil
    guard !pending.isValidSameBoot() else { fatalError("Missing boot deadline restored pairing") }
    pending = restoredPending
    pending.trustGeneration = 0
    guard !pending.isValidSameBoot() else { fatalError("Missing trust generation restored pairing") }
    pending = restoredPending
    pending.localIsInitiator = false
    guard !pending.isValidSameBoot() else { fatalError("Role-inconsistent peer context restored pairing") }

    let reloadedStore = FloatcutSyncIdentityStore(
        defaults: defaults,
        keyTag: keyTag,
        certificateLabel: certificateLabel
    )
    let reloaded = try reloadedStore.loadOrCreate()
    guard reloaded.deviceID == first.deviceID,
          reloaded.certificateSHA256 == first.certificateSHA256,
          reloaded.publicKeyData == first.publicKeyData
    else { fatalError("Identity changed when loaded by a fresh store") }

    defaults.set(Data("invalid-persistent-reference".utf8), forKey: "floatcutSyncIdentityKeyPersistentReference")
    let recoveredStore = FloatcutSyncIdentityStore(
        defaults: defaults,
        keyTag: keyTag,
        certificateLabel: certificateLabel
    )
    let recovered = try recoveredStore.loadOrCreate()
    guard recovered.deviceID == first.deviceID,
          recovered.certificateSHA256 == first.certificateSHA256,
          recovered.publicKeyData == first.publicKeyData,
          defaults.array(forKey: "floatcutSyncIdentityKeyPersistentReference") as? [Data] != nil
    else { fatalError("Identity was not recovered from its stable Keychain tag") }

    guard !FloatcutSyncCertificateValidator.validate(
        certificate: first.certificate,
        expectedDeviceID: FloatcutSyncProtocol.uuidV4()
    ) else { fatalError("Certificate with the wrong device SAN was accepted") }

    let expiredStart = Date(timeIntervalSince1970: 946_684_800)
    let expiredEnd = Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: expiredStart)!
    let expiredDER = try FloatcutSyncCertificateBuilder.make(
        deviceID: first.deviceID,
        privateKey: first.privateKey,
        notBefore: expiredStart,
        notAfter: expiredEnd
    )
    guard let expiredCertificate = SecCertificateCreateWithData(nil, expiredDER as CFData),
          !FloatcutSyncCertificateValidator.validate(certificate: expiredCertificate, expectedDeviceID: first.deviceID)
    else { fatalError("Expired certificate was accepted") }

    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(first.identity, &certificate) == errSecSuccess,
          certificate != nil
    else { fatalError("SecIdentity does not expose its certificate") }

    try store.reset()

    let brokenSuiteName = "\(suiteName).broken"
    guard let brokenDefaults = UserDefaults(suiteName: brokenSuiteName) else {
        fatalError("Could not create broken-identity defaults suite")
    }
    brokenDefaults.set(FloatcutSyncProtocol.uuidV4(), forKey: "floatcutSyncDeviceID")
    let brokenStore = FloatcutSyncIdentityStore(
        defaults: brokenDefaults,
        keyTag: Data("\(brokenSuiteName).key".utf8),
        certificateLabel: "Floatcut Broken Sync Identity Test \(suffix)"
    )
    do {
        _ = try brokenStore.loadOrCreate()
        fatalError("A partially missing persisted identity was silently regenerated")
    } catch FloatcutSyncIdentityError.unavailable {
        // A known identity must require a conscious reset instead of changing its pin.
    }
    try brokenStore.reset()
    brokenDefaults.removePersistentDomain(forName: brokenSuiteName)
    defaults.removePersistentDomain(forName: suiteName)
    print("Floatcut sync identity tests passed")
} catch {
    try? store.reset()
    defaults.removePersistentDomain(forName: suiteName)
    fatalError("Identity test failed: \(error)")
}
