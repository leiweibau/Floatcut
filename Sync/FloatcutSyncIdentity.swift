import CryptoKit
import Foundation
import Security

struct FloatcutSyncIdentity {
    let deviceID: String
    let privateKey: SecKey
    let certificate: SecCertificate
    let identity: SecIdentity
    let certificateDER: Data
    let certificateSHA256: String
    let publicKeyData: Data
}

enum FloatcutSyncIdentityError: Error, LocalizedError {
    case unavailable(String)
    case keychain(String, OSStatus)
    case certificateBuild
    case certificateProfile

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Lokale Sync-Identität nicht verfügbar: \(detail)"
        case .keychain(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain-Fehler bei \(operation): \(status) (\(detail))"
        case .certificateBuild: return "Das lokale Sync-Zertifikat konnte nicht erzeugt werden."
        case .certificateProfile: return "Das lokale Sync-Zertifikat entspricht nicht dem Floatcut-Profil."
        }
    }
}

final class FloatcutSyncIdentityStore {
    static let shared = FloatcutSyncIdentityStore()

    private let defaults: UserDefaults
    private let deviceIDKey = "floatcutSyncDeviceID"
    private let keyPersistentReferenceKey = "floatcutSyncIdentityKeyPersistentReference"
    private let certificateDERKey = "floatcutSyncIdentityCertificateDER"
    private let keyTag: Data
    private let certificateLabel: String
    private let lock = NSLock()
    private var cached: FloatcutSyncIdentity?

    init(
        defaults: UserDefaults = .standard,
        keyTag: Data = Data("de.meierkarsten.floatcut.sync.identity.v1".utf8),
        certificateLabel: String = "Floatcut Sync Identity v1"
    ) {
        self.defaults = defaults
        self.keyTag = keyTag
        self.certificateLabel = certificateLabel
    }

    func loadOrCreate() throws -> FloatcutSyncIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let hasPersistedIdentity = defaults.object(forKey: deviceIDKey) != nil
            || defaults.object(forKey: keyPersistentReferenceKey) != nil
            || defaults.object(forKey: certificateDERKey) != nil
        let deviceID: String
        if let existing = defaults.string(forKey: deviceIDKey) {
            guard FloatcutSyncProtocol.isCanonicalUUID(existing) else {
                throw FloatcutSyncIdentityError.unavailable("ungültige Geräte-ID")
            }
            deviceID = existing
        } else {
            deviceID = FloatcutSyncProtocol.uuidV4()
            defaults.set(deviceID, forKey: deviceIDKey)
        }

        let key: SecKey
        let certificate: SecCertificate
        if hasPersistedIdentity {
            guard let loadedKey = try loadPrivateKey() else {
                throw FloatcutSyncIdentityError.unavailable("der private Schlüssel fehlt; die Identität muss bewusst zurückgesetzt werden")
            }
            guard let loadedCertificate = try loadCertificate() else {
                throw FloatcutSyncIdentityError.unavailable("das Zertifikat fehlt; die Identität muss bewusst zurückgesetzt werden")
            }
            key = loadedKey
            certificate = loadedCertificate
        } else {
            key = try createPrivateKey()
            certificate = try createAndStoreCertificate(deviceID: deviceID, privateKey: key)
        }
        try validate(privateKey: key, matches: certificate)
        guard let identity = makeIdentity(certificate: certificate) else {
            throw FloatcutSyncIdentityError.unavailable("Zertifikat und privater Schlüssel sind nicht verknüpft")
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard SecCertificateCopyKey(certificate) != nil,
              let publicData = FloatcutSyncCertificateValidator.subjectPublicKeyInfo(certificate: certificate),
              FloatcutSyncCertificateValidator.validate(certificate: certificate, expectedDeviceID: deviceID)
        else { throw FloatcutSyncIdentityError.certificateProfile }
        let result = FloatcutSyncIdentity(
            deviceID: deviceID,
            privateKey: key,
            certificate: certificate,
            identity: identity,
            certificateDER: der,
            certificateSHA256: FloatcutSyncProtocol.sha256Hex(der),
            publicKeyData: publicData
        )
        cached = result
        return result
    }

    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        for reference in storedKeyReferences() {
            let keyStatus = SecItemDelete([
                kSecValuePersistentRef as String: reference,
            ] as CFDictionary)
            guard keyStatus == errSecSuccess || keyStatus == errSecItemNotFound || keyStatus == errSecInvalidItemRef else {
                throw FloatcutSyncIdentityError.keychain("Schlüssel löschen", keyStatus)
            }
        }
        let taggedKeyStatus = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
        ] as CFDictionary)
        guard taggedKeyStatus == errSecSuccess || taggedKeyStatus == errSecItemNotFound else {
            throw FloatcutSyncIdentityError.keychain("markierte Schlüssel löschen", taggedKeyStatus)
        }
        if let der = defaults.data(forKey: certificateDERKey),
           let certificate = SecCertificateCreateWithData(nil, der as CFData) {
            let certificateStatus = SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
            ] as CFDictionary)
            guard certificateStatus == errSecSuccess || certificateStatus == errSecItemNotFound || certificateStatus == errSecInvalidItemRef else {
                throw FloatcutSyncIdentityError.keychain("Zertifikat löschen", certificateStatus)
            }
        }
        defaults.removeObject(forKey: deviceIDKey)
        defaults.removeObject(forKey: keyPersistentReferenceKey)
        defaults.removeObject(forKey: certificateDERKey)
        cached = nil
    }

    private func loadPrivateKey() throws -> SecKey? {
        let references = storedKeyReferences()
        for reference in references {
            var item: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecValuePersistentRef as String: reference,
                kSecReturnRef as String: true,
            ] as CFDictionary, &item)
            if status == errSecItemNotFound || status == errSecInvalidItemRef { continue }
            guard status == errSecSuccess, let key = item as! SecKey? else {
                throw FloatcutSyncIdentityError.keychain("Schlüssel laden", status)
            }
            if SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256) {
                return key
            }
        }

        // Persistent Keychain references are an optimization, not the identity's
        // durable locator. macOS may invalidate a reference while retaining the
        // tagged key, for example after replacing a locally signed app bundle.
        // Recover the same private key by its stable application tag and refresh
        // the reference without changing the device identity or its pairings.
        guard let taggedKey = try loadTaggedPrivateKey() else { return nil }
        try storePersistentReference(for: taggedKey)
        return taggedKey
    }

    private func loadTaggedPrivateKey() throws -> SecKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = item as! SecKey? else {
            throw FloatcutSyncIdentityError.keychain("markierten Schlüssel laden", status)
        }
        guard SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256) else {
            throw FloatcutSyncIdentityError.unavailable("der markierte private Schlüssel unterstützt das erforderliche Signaturverfahren nicht")
        }
        return key
    }

    private func createPrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrLabel as String: certificateLabel,
        ]
        var publicKey: SecKey?
        var privateKey: SecKey?
        let generationStatus = SecKeyGeneratePair(attributes as CFDictionary, &publicKey, &privateKey)
        guard generationStatus == errSecSuccess, let key = privateKey else {
            throw FloatcutSyncIdentityError.keychain("Schlüsselpaar erzeugen", generationStatus)
        }
        try storePersistentReference(for: key)
        return key
    }

    private func storePersistentReference(for key: SecKey) throws {
        var reference: CFTypeRef?
        let referenceStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecReturnPersistentRef as String: true,
        ] as CFDictionary, &reference)
        guard referenceStatus == errSecSuccess, reference != nil else {
            throw FloatcutSyncIdentityError.keychain("Schlüsselreferenz speichern", referenceStatus)
        }
        let persistentReferences: [Data]
        if let one = reference as? Data {
            persistentReferences = [one]
        } else if let many = reference as? [Data] {
            persistentReferences = many
        } else {
            throw FloatcutSyncIdentityError.unavailable("ungültige Schlüsselreferenz")
        }
        defaults.set(persistentReferences, forKey: keyPersistentReferenceKey)
    }

    private func storedKeyReferences() -> [Data] {
        if let values = defaults.array(forKey: keyPersistentReferenceKey) as? [Data] { return values }
        if let value = defaults.data(forKey: keyPersistentReferenceKey) { return [value] }
        return []
    }

    private func loadCertificate() throws -> SecCertificate? {
        guard let der = defaults.data(forKey: certificateDERKey) else { return nil }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw FloatcutSyncIdentityError.unavailable("das gespeicherte Zertifikat ist ungültig")
        }
        try addCertificateToKeychain(certificate)
        return certificate
    }

    private func createAndStoreCertificate(deviceID: String, privateKey: SecKey) throws -> SecCertificate {
        let der = try FloatcutSyncCertificateBuilder.make(deviceID: deviceID, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw FloatcutSyncIdentityError.certificateBuild
        }
        try addCertificateToKeychain(certificate)
        defaults.set(der, forKey: certificateDERKey)
        return certificate
    }

    private func addCertificateToKeychain(_ certificate: SecCertificate) throws {
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certificateLabel,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw FloatcutSyncIdentityError.keychain("Zertifikat speichern", status)
        }
    }

    private func makeIdentity(certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess
        else { return nil }
        return identity
    }

    private func validate(privateKey: SecKey, matches certificate: SecCertificate) throws {
        guard let certificatePublicKey = SecCertificateCopyKey(certificate) else {
            throw FloatcutSyncIdentityError.unavailable("das Zertifikat enthält keinen verwendbaren öffentlichen Schlüssel")
        }
        // SecKeyCopyPublicKey may return nil for a legacy login-Keychain key
        // after the creating process or app bundle has been replaced. Prove
        // the association by signing a fixed, non-secret challenge instead.
        let challenge = Data("FLOATCUT-SYNC-IDENTITY-CHECK-V1".utf8)
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            &signingError
        ) as Data? else {
            _ = signingError?.takeRetainedValue()
            throw FloatcutSyncIdentityError.unavailable("der private Schlüssel kann nicht zum Signieren verwendet werden")
        }
        var verificationError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(
            certificatePublicKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            signature as CFData,
            &verificationError
        ) else {
            _ = verificationError?.takeRetainedValue()
            throw FloatcutSyncIdentityError.unavailable("Zertifikat und privater Schlüssel gehören nicht zusammen")
        }
    }
}

enum FloatcutSyncCertificateBuilder {
    static func make(deviceID: String, privateKey: SecKey, notBefore: Date? = nil, notAfter: Date? = nil) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw FloatcutSyncIdentityError.certificateBuild }

        let signatureAlgorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let commonName = "Floatcut \(deviceID)"
        let name = DER.sequence(DER.set(DER.sequence(
            DER.oid([2, 5, 4, 3]) + DER.utf8String(commonName)
        )))
        let starts = notBefore ?? Date().addingTimeInterval(-300)
        let expires = notAfter ?? Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: starts)!
        let validity = DER.sequence(DER.time(starts) + DER.time(expires))
        let subjectPublicKeyInfo = DER.sequence(
            DER.sequence(DER.oid([1, 2, 840, 10045, 2, 1]) + DER.oid([1, 2, 840, 10045, 3, 1, 7]))
            + DER.bitString(publicData)
        )
        let basicConstraints = DER.sequence(
            DER.oid([2, 5, 29, 19]) + DER.boolean(true) + DER.octetString(DER.sequence(Data()))
        )
        let keyUsageValue = DER.tlv(tag: 0x03, content: Data([0x07, 0x80]))
        let keyUsage = DER.sequence(
            DER.oid([2, 5, 29, 15]) + DER.boolean(true) + DER.octetString(keyUsageValue)
        )
        let extendedKeyUsageValue = DER.sequence(
            DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]) + DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 2])
        )
        let extendedKeyUsage = DER.sequence(
            DER.oid([2, 5, 29, 37]) + DER.octetString(extendedKeyUsageValue)
        )
        let sanURI = Data("urn:floatcut:device:\(deviceID)".utf8)
        let subjectAlternativeName = DER.sequence(
            DER.oid([2, 5, 29, 17]) + DER.octetString(DER.sequence(DER.tlv(tag: 0x86, content: sanURI)))
        )
        let extensions = DER.explicit(tagNumber: 3, content: DER.sequence(
            basicConstraints + keyUsage + extendedKeyUsage + subjectAlternativeName
        ))
        let serial = try FloatcutSyncProtocol.secureNonce().prefix(16)
        let tbs = DER.sequence(
            DER.explicit(tagNumber: 0, content: DER.integer(Data([0x02])))
            + DER.integer(Data(serial))
            + signatureAlgorithm
            + name
            + validity
            + name
            + subjectPublicKeyInfo
            + extensions
        )
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &signingError
        ) as Data? else {
            throw FloatcutSyncIdentityError.unavailable(signingError?.takeRetainedValue().localizedDescription ?? "Zertifikatsignatur fehlgeschlagen")
        }
        return DER.sequence(tbs + signatureAlgorithm + DER.bitString(signature))
    }
}

enum FloatcutSyncCertificateValidator {
    static func subjectPublicKeyInfo(certificate: SecCertificate) -> Data? {
        let der = SecCertificateCopyData(certificate) as Data
        guard let root = try? DERReader(data: der).rootSequenceChildren(),
              let tbs = try? DERReader(data: root[0].content).children(),
              tbs.count > 6, tbs[6].tag == 0x30
        else { return nil }
        return tbs[6].encoded
    }

    static func validate(certificate: SecCertificate, expectedDeviceID: String) -> Bool {
        let der = SecCertificateCopyData(certificate) as Data
        guard validateProfileDER(der, expectedDeviceID: expectedDeviceID),
              let publicKey = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue == 256,
              verifySelfSignature(certificate: certificate, publicKey: publicKey),
              verifyDates(certificate: certificate)
        else { return false }
        return true
    }

    private static func validateProfileDER(_ der: Data, expectedDeviceID: String) -> Bool {
        guard let root = try? DERReader(data: der).rootSequenceChildren(), root.count == 3,
              let tbs = try? DERReader(data: root[0].content).children(), tbs.count >= 8,
              tbs[0].tag == 0xa0,
              tbs[3].encoded == tbs[5].encoded,
              tbs[2].encoded == root[1].encoded,
              let extensionWrapper = tbs.first(where: { $0.tag == 0xa3 }),
              let extensionSequence = try? DERReader(data: extensionWrapper.content).single(tag: 0x30),
              let extensions = try? DERReader(data: extensionSequence.content).children()
        else { return false }

        var values: [Data: Data] = [:]
        for item in extensions where item.tag == 0x30 {
            guard let parts = try? DERReader(data: item.content).children(),
                  parts.count == 2 || parts.count == 3,
                  parts[0].tag == 0x06,
                  let value = parts.last, value.tag == 0x04
            else { return false }
            guard values[parts[0].encoded] == nil else { return false }
            values[parts[0].encoded] = value.content
        }

        let basicOID = DER.oid([2, 5, 29, 19])
        let keyUsageOID = DER.oid([2, 5, 29, 15])
        let extendedKeyUsageOID = DER.oid([2, 5, 29, 37])
        let sanOID = DER.oid([2, 5, 29, 17])
        guard let basic = values[basicOID],
              let basicSequence = try? DERReader(data: basic).single(tag: 0x30),
              let basicParts = try? DERReader(data: basicSequence.content).children(),
              basicParts.isEmpty || (basicParts.count == 1 && basicParts[0].tag == 0x01 && basicParts[0].content == Data([0x00])),
              let keyUsage = values[keyUsageOID],
              let keyBits = try? DERReader(data: keyUsage).single(tag: 0x03),
              keyBits.content == Data([0x07, 0x80]),
              let extended = values[extendedKeyUsageOID],
              let extendedSequence = try? DERReader(data: extended).single(tag: 0x30),
              let extendedParts = try? DERReader(data: extendedSequence.content).children(),
              Set(extendedParts.map(\.encoded)) == Set([
                  DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]),
                  DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 2]),
              ]),
              let san = values[sanOID],
              let sanSequence = try? DERReader(data: san).single(tag: 0x30),
              let names = try? DERReader(data: sanSequence.content).children(),
              names.contains(where: {
                  $0.tag == 0x86 && $0.content == Data("urn:floatcut:device:\(expectedDeviceID)".utf8)
              }),
              validateTenYearValidity(tbs[4])
        else { return false }
        return true
    }

    private static func validateTenYearValidity(_ validity: DERTLV) -> Bool {
        guard validity.tag == 0x30,
              let parts = try? DERReader(data: validity.content).children(),
              parts.count == 2,
              let notBefore = parseDERTime(parts[0]),
              let notAfter = parseDERTime(parts[1])
        else { return false }
        let days = notAfter.timeIntervalSince(notBefore) / 86_400
        return days >= 3_650 && days <= 3_654
    }

    private static func parseDERTime(_ value: DERTLV) -> Date? {
        guard var string = String(data: value.content, encoding: .ascii), string.hasSuffix("Z") else { return nil }
        let format: String
        switch value.tag {
        case 0x17:
            guard string.count == 13, let shortYear = Int(string.prefix(2)) else { return nil }
            string = String(shortYear >= 50 ? 1900 + shortYear : 2000 + shortYear) + string.dropFirst(2)
            format = "yyyyMMddHHmmss'Z'"
        case 0x18: format = "yyyyMMddHHmmss'Z'"
        default: return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.date(from: string)
    }

    private static func verifySelfSignature(certificate: SecCertificate, publicKey: SecKey) -> Bool {
        let der = SecCertificateCopyData(certificate) as Data
        guard let root = try? DERReader(data: der).rootSequenceChildren(), root.count == 3,
              root[0].tag == 0x30, root[2].tag == 0x03,
              root[2].content.first == 0
        else { return false }
        return SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            root[0].encoded as CFData,
            root[2].content.dropFirst() as CFData,
            nil
        )
    }

    private static func verifyDates(certificate: SecCertificate) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

private enum DER {
    static func tlv(tag: UInt8, content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }
    static func sequence(_ content: Data) -> Data { tlv(tag: 0x30, content: content) }
    static func set(_ content: Data) -> Data { tlv(tag: 0x31, content: content) }
    static func integer(_ value: Data) -> Data {
        var bytes = value.drop(while: { $0 == 0 })
        if bytes.isEmpty { bytes = Data([0]) }
        var content = Data(bytes)
        if content.first! & 0x80 != 0 { content.insert(0, at: 0) }
        return tlv(tag: 0x02, content: content)
    }
    static func boolean(_ value: Bool) -> Data { tlv(tag: 0x01, content: Data([value ? 0xff : 0])) }
    static func octetString(_ value: Data) -> Data { tlv(tag: 0x04, content: value) }
    static func bitString(_ value: Data) -> Data { tlv(tag: 0x03, content: Data([0]) + value) }
    static func utf8String(_ value: String) -> Data { tlv(tag: 0x0c, content: Data(value.utf8)) }
    static func explicit(tagNumber: UInt8, content: Data) -> Data { tlv(tag: 0xa0 | tagNumber, content: content) }
    static func time(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: value)
        formatter.dateFormat = year >= 1950 && year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(tag: year >= 1950 && year < 2050 ? 0x17 : 0x18, content: Data(formatter.string(from: value).utf8))
    }
    static func oid(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for value in components.dropFirst(2) {
            var value = value
            var encoded = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7f) | 0x80, at: 0)
                value >>= 7
            }
            body.append(contentsOf: encoded)
        }
        return tlv(tag: 0x06, content: body)
    }
    private static func length(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var length = value
        var bytes = [UInt8]()
        while length > 0 {
            bytes.insert(UInt8(length & 0xff), at: 0)
            length >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

private struct DERTLV {
    let tag: UInt8
    let content: Data
    let encoded: Data
}

private struct DERReader {
    let data: Data

    func rootSequenceChildren() throws -> [DERTLV] {
        var offset = 0
        let root = try read(at: &offset)
        guard root.tag == 0x30, offset == data.count else { throw FloatcutSyncIdentityError.certificateBuild }
        var children: [DERTLV] = []
        var childOffset = 0
        while childOffset < root.content.count {
            children.append(try DERReader(data: root.content).read(at: &childOffset))
        }
        return children
    }

    func children() throws -> [DERTLV] {
        var result: [DERTLV] = []
        var offset = 0
        while offset < data.count { result.append(try read(at: &offset)) }
        return result
    }

    func single(tag: UInt8) throws -> DERTLV {
        var offset = 0
        let value = try read(at: &offset)
        guard value.tag == tag, offset == data.count else { throw FloatcutSyncIdentityError.certificateBuild }
        return value
    }

    private func read(at offset: inout Int) throws -> DERTLV {
        let start = offset
        guard offset < data.count else { throw FloatcutSyncIdentityError.certificateBuild }
        let tag = data[offset]
        offset += 1
        guard offset < data.count else { throw FloatcutSyncIdentityError.certificateBuild }
        var length = Int(data[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, offset + count <= data.count else { throw FloatcutSyncIdentityError.certificateBuild }
            length = 0
            for byte in data[offset..<(offset + count)] { length = (length << 8) | Int(byte) }
            offset += count
        }
        guard length >= 0, offset + length <= data.count else { throw FloatcutSyncIdentityError.certificateBuild }
        let content = data.subdata(in: offset..<(offset + length))
        offset += length
        return DERTLV(tag: tag, content: content, encoded: data.subdata(in: start..<offset))
    }
}

struct FloatcutSyncPeer: Codable, Identifiable, Equatable {
    let deviceID: String
    var name: String
    var platform: String
    let certificateSHA256: String
    let certificateDERBase64: String
    var pairedAtMS: Int64
    var lastSeenMS: Int64
    var capabilities: [String]
    var enabled: Bool
    var identityMismatch: Bool
    var allowsOutgoingImages: Bool
    var id: String { deviceID }

    private enum CodingKeys: String, CodingKey {
        case deviceID, name, platform, certificateSHA256, certificateDERBase64
        case pairedAtMS, lastSeenMS, capabilities, enabled, identityMismatch, allowsOutgoingImages
    }

    init(deviceID: String, name: String, platform: String, certificateSHA256: String,
         certificateDERBase64: String, pairedAtMS: Int64, lastSeenMS: Int64,
         capabilities: [String], enabled: Bool, identityMismatch: Bool,
         allowsOutgoingImages: Bool = false) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.certificateSHA256 = certificateSHA256
        self.certificateDERBase64 = certificateDERBase64
        self.pairedAtMS = pairedAtMS
        self.lastSeenMS = lastSeenMS
        self.capabilities = capabilities
        self.enabled = enabled
        self.identityMismatch = identityMismatch
        self.allowsOutgoingImages = allowsOutgoingImages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        name = try values.decode(String.self, forKey: .name)
        platform = try values.decode(String.self, forKey: .platform)
        certificateSHA256 = try values.decode(String.self, forKey: .certificateSHA256)
        certificateDERBase64 = try values.decode(String.self, forKey: .certificateDERBase64)
        pairedAtMS = try values.decode(Int64.self, forKey: .pairedAtMS)
        lastSeenMS = try values.decode(Int64.self, forKey: .lastSeenMS)
        capabilities = try values.decode([String].self, forKey: .capabilities)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        identityMismatch = try values.decode(Bool.self, forKey: .identityMismatch)
        allowsOutgoingImages = try values.decodeIfPresent(Bool.self, forKey: .allowsOutgoingImages) ?? false
    }
}

struct FloatcutSyncPendingPairing: Codable, Equatable {
    let requestID: String
    let peerDeviceID: String
    let peerCertificateSHA256: String
    let peerCertificateDERBase64: String
    let transcriptSHA256: String
    let expiresAtMS: Int64
    var localIsInitiator: Bool?
    var localConfirmed: Bool
    var remoteConfirmed: Bool
    var complete: Bool
}

struct FloatcutSyncRevocation: Codable, Identifiable, Equatable {
    let peerDeviceID: String
    let certificateSHA256: String
    let revocationID: String
    let revokedAtMS: Int64
    var acknowledged: Bool
    var id: String { revocationID }
}

final class FloatcutSyncPersistentStore<Record: Codable> {
    private let url: URL
    private let queue: DispatchQueue
    private var records: [Record] = []
    private var loadFailed = false

    init(fileName: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.meierkarsten.floatcut", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(fileName)
        queue = DispatchQueue(label: "de.meierkarsten.floatcut.sync.store.\(fileName)")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
            } catch {
                // Fail closed and preserve the malformed file for diagnosis. Only
                // an explicit replace (identity reset) may overwrite it.
                loadFailed = true
            }
        }
    }

    func read() -> [Record] { queue.sync { records } }

    func replace(_ newRecords: [Record]) throws {
        try queue.sync {
            let data = try JSONEncoder.floatcutSync.encode(newRecords)
            try data.write(to: url, options: .atomic)
            records = newRecords
            loadFailed = false
        }
    }

    func mutate(_ body: (inout [Record]) throws -> Void) throws {
        try queue.sync {
            guard !loadFailed else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            var copy = records
            try body(&copy)
            let data = try JSONEncoder.floatcutSync.encode(copy)
            try data.write(to: url, options: .atomic)
            records = copy
        }
    }
}

extension JSONEncoder {
    fileprivate static var floatcutSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
