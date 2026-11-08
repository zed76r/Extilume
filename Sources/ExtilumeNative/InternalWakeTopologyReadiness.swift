import ExtilumeCore
import Foundation

// Only a previously confirmed, write-free C can authorize read-only wake waiting.
struct InternalWakeTopologyReadiness {
    let record: RecoveryRecord
    let snapshot: Snapshot

    init(record: RecoveryRecord, snapshot: Snapshot) throws {
        try record.validate()
        guard record.phase == .owned, !record.requiresRecovery, !record.sourceUnresolved,
              record.externalDisplay == nil,
              let internalDisplay = record.internalDisplay, internalDisplay.baseline,
              internalDisplay.hardwareIdentity != nil,
              snapshot.assessment.isSupported, snapshot.displays.count == 2,
              snapshot.displays.filter({ $0.identity == .physical }).count == 1,
              snapshot.displays.allSatisfy({ $0.isActive && $0.isOnline && !$0.isMirrored }),
              try snapshot.layout() == record.baseline else { throw RecoveryError.unresolvedSource }
        _ = try snapshot.builtInDisplay(identity: internalDisplay.identity)
        self.record = record
        self.snapshot = snapshot
    }

    func isWaiting(current: Snapshot, internalState: InternalDisplayState, record: RecoveryRecord) throws -> Bool {
        guard record == self.record, let responsibility = record.internalDisplay,
              internalState.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity),
              internalState.isEnabled else { throw RecoveryError.identityConflict }
        let expected = try snapshot.builtInDisplay(identity: responsibility.identity)
        let actual = try current.builtInDisplay(identity: responsibility.identity)
        guard actual == expected, actual.id == internalState.id,
              actual.isActive == internalState.isActive, actual.isOnline == internalState.isOnline else {
            throw RecoveryError.identityConflict
        }
        if current.displays.count == 1 { return true }
        guard current.displays.count == snapshot.displays.count,
              current.displays.allSatisfy({ snapshot.displays.contains($0) }),
              try current.layout() == record.baseline else { throw RecoveryError.unresolvedSource }
        return false
    }

    func verifyComplete(current: Snapshot, record: RecoveryRecord) throws {
        guard record == self.record, !record.requiresRecovery, !record.sourceUnresolved,
              current == snapshot else { throw RecoveryError.identityConflict }
    }
}

struct InternalNormalWakeReapplication {
    let epoch: UUID
    let topology: InternalWakeTopologyReadiness
    let verifiedAt: UInt64

    func verify(current: Snapshot, record: RecoveryRecord, epoch: UUID) throws {
        guard epoch == self.epoch else { throw InternalControlCancellation.pauseRequested }
        try topology.verifyComplete(current: current, record: record)
    }

    func verifyPrepared(_ prepared: RecoveryRecord, epoch: UUID) throws {
        guard epoch == self.epoch else { throw InternalControlCancellation.pauseRequested }
        guard prepared.session == topology.record.session, prepared.baseline == topology.record.baseline,
              prepared.generation > topology.record.generation,
              prepared.generation - topology.record.generation == 1 else { throw RecoveryError.identityConflict }
    }
}
