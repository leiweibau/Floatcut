import Foundation

func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError(label) }
}

// T07/T08: one reservation and a discovery flood cannot bypass deadline.
let scheduler = FloatcutSyncPeerScheduler()
expect(scheduler.canStart(now: 0, eligible: true), "first eligible attempt must start immediately")
let attempt = UUID()
expect(scheduler.reserve(attempt), "first reservation failed")
expect(!scheduler.canStart(now: 0, eligible: true), "reservation allowed parallel attempt")
let firstDeadline = scheduler.recordAutomaticFailure(now: 0, randomMultiplier: 1)
expect(firstDeadline == 1 && scheduler.failures == 1, "first backoff is not one second")
for _ in 0..<100 { expect(!scheduler.canStart(now: 0.5, eligible: true), "browse update bypassed backoff") }
scheduler.discoveryLost()
expect(!scheduler.canStart(now: 0.9, eligible: true), "rediscovery before deadline bypassed backoff")
expect(scheduler.canStart(now: 1, eligible: true), "retry did not become eligible at deadline")
let second = UUID()
expect(scheduler.reserve(second), "second reservation failed")
expect(scheduler.recordAutomaticFailure(now: 1, randomMultiplier: 1) == 3, "second deadline is not cumulative")

// R1/R3: security suspension survives harmless DNS-SD updates and success
// clears only normal retry state.
scheduler.suspendForSecurity()
expect(!scheduler.canStart(now: 3, eligible: true), "security suspension was bypassed")
scheduler.clearSecuritySuspension()
expect(scheduler.canStart(now: 3, eligible: true), "explicit suspension clear did not re-enable scheduling")
scheduler.succeed()
expect(scheduler.failures == 0 && scheduler.nextAttemptAt == 0, "success did not reset retry state")

// T09: elapsed-time deadlines are independent of wall clock and received data
// extends the deadline exactly from the actual receive instant.
var liveness = FloatcutSyncLiveness(now: 0)
expect(liveness.pingDeadline() == 30 && liveness.receiveDeadline() == 90, "initial liveness deadlines incorrect")
expect(!liveness.isExpired(at: 89), "connection expired before receive deadline")
liveness.received(at: 89)
expect(liveness.receiveDeadline() == 179 && !liveness.isExpired(at: 90), "receive activity did not extend deadline")
expect(liveness.isExpired(at: 179), "connection did not expire at elapsed deadline")

// T14: stale UI work cannot replace the current epoch or revision.
let gate = FloatcutSyncSnapshotGate()
let epoch1 = gate.beginEpoch()
expect(gate.accepts(epoch: epoch1, revision: 1), "first snapshot rejected")
expect(!gate.accepts(epoch: epoch1, revision: 1), "equal snapshot revision accepted")
let epoch2 = gate.beginEpoch()
expect(!gate.accepts(epoch: epoch1, revision: 2), "stale engine snapshot accepted")
expect(gate.accepts(epoch: epoch2, revision: 1), "new epoch snapshot rejected")


let bootGeneration = "11223344-5566-4788-99aa-bbccddeeff00"
let fixedDeadline = FloatcutSyncBootDeadline.starting(durationMS: 120_000, nowTickMS: 5_000, bootGeneration: bootGeneration)!
expect(fixedDeadline.isValid(durationMS: 120_000, nowTickMS: 5_000, bootGeneration: bootGeneration), "request start invalid")
let restoredDeadline = try JSONDecoder().decode(FloatcutSyncBootDeadline.self, from: JSONEncoder().encode(fixedDeadline))
expect(restoredDeadline.isValid(durationMS: 120_000, nowTickMS: 124_999, bootGeneration: bootGeneration), "same-boot process restart lost valid deadline")
expect(!restoredDeadline.isValid(durationMS: 120_000, nowTickMS: 125_000, bootGeneration: bootGeneration), "deadline equality must expire")
expect(!restoredDeadline.isValid(durationMS: 120_000, nowTickMS: 4_999, bootGeneration: bootGeneration), "clock rollback renewed deadline")
expect(!restoredDeadline.isValid(durationMS: 120_000, nowTickMS: 6_000, bootGeneration: UUID().uuidString.lowercased()), "new boot resumed old pairing")
expect(!restoredDeadline.isValid(durationMS: 120_000, nowTickMS: 6_000, bootGeneration: nil), "missing boot marker resumed old pairing")
expect(!restoredDeadline.isValid(durationMS: 600_000, nowTickMS: 6_000, bootGeneration: bootGeneration), "corrupt duration accepted")
expect(FloatcutSyncBootDeadline.starting(durationMS: 120_000, nowTickMS: UInt64.max - 1, bootGeneration: bootGeneration) == nil, "overflowing deadline accepted")
expect(FloatcutSyncBootClock.nowTickMS() != nil && FloatcutSyncBootClock.generation() != nil, "native boot clock unavailable")

print("Sync lifecycle tests passed")
