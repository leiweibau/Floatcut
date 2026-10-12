import Foundation
import Darwin

/// Runtime scheduling uses this elapsed clock; persisted protocol timestamps keep
/// using Unix milliseconds in `FloatcutSyncCoordinator`.
protocol FloatcutSyncElapsedClock {
    func now() -> TimeInterval
}

final class FloatcutSyncContinuousClock: FloatcutSyncElapsedClock {
    private let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    func now() -> TimeInterval {
        // Unlike DispatchTime.uptimeNanoseconds, continuous time includes sleep.
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

/// Pairing persistence uses the kernel boot session and sleep-inclusive elapsed
/// ticks; neither wall-clock adjustments nor process restarts renew a request.
enum FloatcutSyncBootClock {
    static let clockID = "mach_continuous_time_ms_v1"

    static func generation() -> String? {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1, length <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0,
              bytes.contains(0) else { return nil }
        let value = String(cString: bytes).lowercased()
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static func nowTickMS() -> UInt64? {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return nil }
        let divisor = UInt64(base.denom).multipliedReportingOverflow(by: 1_000_000)
        guard !divisor.overflow else { return nil }
        let wide = mach_continuous_time().multipliedFullWidth(by: UInt64(base.numer))
        guard wide.high < divisor.partialValue else { return nil }
        return divisor.partialValue.dividingFullWidth(wide).quotient
    }
}

struct FloatcutSyncBootDeadline: Codable, Equatable {
    let localBootGeneration: String
    let clockID: String
    let startTickMS: UInt64
    let deadlineTickMS: UInt64

    static func starting(durationMS: UInt64, nowTickMS: UInt64? = FloatcutSyncBootClock.nowTickMS(),
                         bootGeneration: String? = FloatcutSyncBootClock.generation()) -> FloatcutSyncBootDeadline? {
        guard let nowTickMS, let bootGeneration, UUID(uuidString: bootGeneration) != nil else { return nil }
        let end = nowTickMS.addingReportingOverflow(durationMS)
        guard !end.overflow, durationMS > 0 else { return nil }
        return FloatcutSyncBootDeadline(localBootGeneration: bootGeneration, clockID: FloatcutSyncBootClock.clockID,
                                        startTickMS: nowTickMS, deadlineTickMS: end.partialValue)
    }

    func isValid(durationMS: UInt64, nowTickMS: UInt64? = FloatcutSyncBootClock.nowTickMS(),
                 bootGeneration: String? = FloatcutSyncBootClock.generation()) -> Bool {
        guard let nowTickMS, let bootGeneration, clockID == FloatcutSyncBootClock.clockID,
              localBootGeneration == bootGeneration, UUID(uuidString: bootGeneration) != nil,
              deadlineTickMS >= startTickMS, deadlineTickMS - startTickMS == durationMS
        else { return false }
        return startTickMS <= nowTickMS && nowTickMS < deadlineTickMS
    }
}

enum FloatcutSyncAttemptPurpose: String {
    case trusted
    case pairingResume
    case revocation
    case newPairing

    var automaticallyRetries: Bool {
        switch self {
        case .trusted, .pairingResume, .revocation: return true
        case .newPairing: return false
        }
    }
}

/// Immutable context kept from reservation through TLS/HELLO completion. The
/// target is deliberately distinct from the device ID learned from HELLO.
struct FloatcutSyncAttempt {
    let engineEpoch: UInt64
    let id: UUID
    let targetDeviceID: String
    let purpose: FloatcutSyncAttemptPurpose
    let endpointKey: String
    let expectedPin: String?
    let startedAt: TimeInterval
    let establishmentDeadline: TimeInterval
}

/// Per-peer, network-queue owned retry state. The owner supplies timers; this
/// object makes the eligibility and deadline decisions deterministic and easy
/// to exercise without Network.framework.
final class FloatcutSyncPeerScheduler {
    private(set) var failures = 0
    private(set) var nextAttemptAt: TimeInterval = 0
    private(set) var reservation: UUID?
    private(set) var generation: UInt64 = 0
    private(set) var securitySuspended = false

    func canStart(now: TimeInterval, eligible: Bool, allowImmediate: Bool = false) -> Bool {
        eligible && !securitySuspended && reservation == nil && (allowImmediate || now >= nextAttemptAt)
    }

    func reserve(_ id: UUID) -> Bool {
        guard reservation == nil else { return false }
        reservation = id
        return true
    }

    func releaseReservation(_ id: UUID) {
        guard reservation == id else { return }
        reservation = nil
    }

    @discardableResult
    func recordAutomaticFailure(now: TimeInterval, randomMultiplier: Double) -> TimeInterval {
        reservation = nil
        failures = min(failures + 1, 6)
        let base = min(pow(2.0, Double(failures - 1)), 30)
        let multiplier = min(1.2, max(0.8, randomMultiplier))
        nextAttemptAt = now + min(30, base * multiplier)
        generation &+= 1
        return nextAttemptAt
    }

    func succeed() {
        failures = 0
        nextAttemptAt = 0
        reservation = nil
        generation &+= 1
    }

    /// Discovery loss only invalidates a currently armed timer. It retains the
    /// deadline so rediscovery cannot bypass backoff.
    func discoveryLost() { generation &+= 1 }

    func invalidateTimer() { generation &+= 1 }

    func suspendForSecurity() {
        securitySuspended = true
        reservation = nil
        generation &+= 1
    }

    func clearSecuritySuspension() {
        securitySuspended = false
        generation &+= 1
    }
}

/// Deadline calculation is isolated so wall-clock adjustments cannot change
/// online liveness decisions.
struct FloatcutSyncLiveness {
    private(set) var lastReceived: TimeInterval
    private(set) var lastSent: TimeInterval

    init(now: TimeInterval) {
        lastReceived = now
        lastSent = now
    }

    mutating func received(at now: TimeInterval) { lastReceived = now }
    mutating func sent(at now: TimeInterval) { lastSent = now }
    func receiveDeadline() -> TimeInterval { lastReceived + 90 }
    func pingDeadline() -> TimeInterval { lastSent + 30 }
    func isExpired(at now: TimeInterval) -> Bool { now >= receiveDeadline() }
    func nextDeadline() -> TimeInterval { min(receiveDeadline(), pingDeadline()) }
}

/// Prevents delayed main-queue closures from an old engine from overwriting a
/// newer sync session. Revisions are shared between all snapshot categories.
final class FloatcutSyncSnapshotGate {
    private(set) var epoch: UInt64 = 0
    private(set) var lastAcceptedRevision: UInt64 = 0

    @discardableResult
    func beginEpoch() -> UInt64 {
        epoch &+= 1
        lastAcceptedRevision = 0
        return epoch
    }

    func accepts(epoch: UInt64, revision: UInt64) -> Bool {
        guard epoch == self.epoch, revision > lastAcceptedRevision else { return false }
        lastAcceptedRevision = revision
        return true
    }
}
