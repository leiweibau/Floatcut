import Foundation
import Security

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
guard peerWithoutImageSetting.allowsOutgoingImages == false else {
    fatalError("A peer without allowsOutgoingImages did not fail closed")
}
var peerWithImageSetting = peerWithoutImageSetting
peerWithImageSetting.allowsOutgoingImages = true
let peerRoundTrip = try JSONDecoder().decode([FloatcutSyncPeer].self, from: JSONEncoder().encode([peerWithImageSetting]))[0]
guard peerRoundTrip.allowsOutgoingImages, peerRoundTrip.enabled,
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
