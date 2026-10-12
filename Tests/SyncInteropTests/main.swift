import Foundation

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artifacts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
func fixture(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(name)))
}
let pairingVectors = try fixture("pairing-vectors.json") as! [[String: Any]]
var objects: [[String: Any]] = [try fixture("clipboard-update.json") as! [String: Any]]
var channels = ["control"]
for name in ["image-transfer.json", "file-transfer.json", "control-messages.json", "progress-messages.json"] {
    let messages = (try fixture(name) as! [String: Any])["messages"] as! [[String: Any]]
    objects.append(contentsOf: messages)
    channels.append(contentsOf: Array(repeating: "control", count: messages.count))
}
for vector in pairingVectors {
    let messages = vector["messages"] as! [[String: Any]]
    objects.append(contentsOf: messages)
    channels.append(contentsOf: Array(repeating: "control", count: messages.count))
}
let file = try fixture("file-transfer.json") as! [String: Any]
let preludes = file["data_messages"] as! [[String: Any]]
objects.append(contentsOf: preludes)
channels.append(contentsOf: Array(repeating: "file", count: preludes.count))
var frames = Data()
for (index, object) in objects.enumerated() {
    let message = try FloatcutSyncWireMessage(object: object)
    let maximum = channels[index] == "file" ? FloatcutSyncProtocol.maximumFilePreludeBytes : FloatcutSyncProtocol.maximumFrameBytes
    let encoded = try FloatcutSyncCodec.encode(message, maximumFrameBytes: maximum)
    var decoder = FloatcutSyncFrameDecoder(maximumFrameBytes: maximum)
    var decoded = [FloatcutSyncWireMessage]()
    for byte in encoded { decoded.append(contentsOf: try decoder.append(Data([byte]))) }
    try decoder.finish()
    precondition(decoded.count == 1 && NSDictionary(dictionary: decoded[0].object).isEqual(to: object))
    frames.append(encoded)
}
try frames.write(to: artifacts.appendingPathComponent("floatcut-v3.frames"))
try JSONSerialization.data(withJSONObject: channels).write(to: artifacts.appendingPathComponent("channels.json"))

var results = [[String: Any]]()
for vector in pairingVectors {
    let iid = vector["initiator_device_id"] as! String
    let aid = vector["acceptor_device_id"] as! String
    let ipin = vector["initiator_certificate_sha256"] as! String
    let apin = vector["acceptor_certificate_sha256"] as! String
    let request = vector["request_id"] as! String
    let binding = try FloatcutSyncProtocol.controlBinding(dialerDeviceID: iid, dialerCertificateSHA256: ipin,
        dialerNonce: FloatcutSyncProtocol.dataFromHex(vector["initiator_hello_nonce_hex"] as! String),
        listenerDeviceID: aid, listenerCertificateSHA256: apin,
        listenerNonce: FloatcutSyncProtocol.dataFromHex(vector["acceptor_hello_nonce_hex"] as! String))
    let inonce = try FloatcutSyncProtocol.dataFromHex(vector["initiator_nonce_hex"] as! String)
    let anonce = try FloatcutSyncProtocol.dataFromHex(vector["acceptor_nonce_hex"] as! String)
    let icommit = try FloatcutSyncProtocol.pairingCommitment(role: "initiator", requestID: request, controlBindingSHA256: binding,
        initiatorDeviceID: iid, initiatorCertificateSHA256: ipin, acceptorDeviceID: aid, acceptorCertificateSHA256: apin, nonce: inonce)
    let acommit = try FloatcutSyncProtocol.pairingCommitment(role: "acceptor", requestID: request, controlBindingSHA256: binding,
        initiatorDeviceID: iid, initiatorCertificateSHA256: ipin, acceptorDeviceID: aid, acceptorCertificateSHA256: apin, nonce: anonce)
    let transcript = try FloatcutSyncProtocol.pairingTranscript(requestID: request, controlBindingSHA256: binding,
        initiatorDeviceID: iid, initiatorCertificateSHA256: ipin, initiatorNonce: inonce,
        acceptorDeviceID: aid, acceptorCertificateSHA256: apin, acceptorNonce: anonce,
        initiatorCommitmentSHA256: icommit, acceptorCommitmentSHA256: acommit)
    results.append(["control_binding_sha256": binding, "initiator_commitment_sha256": icommit,
        "acceptor_commitment_sha256": acommit, "transcript_sha256": transcript.sha256, "comparison_code": transcript.comparisonCode])
}
let offer = (file["messages"] as! [[String: Any]])[0]
let digest = try FloatcutSyncProtocol.fileOfferDigest(transferID: offer["transfer_id"] as! String,
    controlBindingSHA256: file["control_binding_sha256"] as! String, senderDeviceID: file["sender_device_id"] as! String,
    receiverDeviceID: file["receiver_device_id"] as! String, byteSize: (offer["byte_size"] as! NSNumber).int64Value,
    contentSHA256: offer["content_sha256"] as! String, fileName: offer["file_name"] as! String)
try JSONSerialization.data(withJSONObject: ["pairing": results, "offer_sha256": digest])
    .write(to: artifacts.appendingPathComponent("floatcut-v3-digests.json"))
print("Swift V3 fixture codec: \(objects.count) messages, fragmented round trips, pairing/offer digests")
