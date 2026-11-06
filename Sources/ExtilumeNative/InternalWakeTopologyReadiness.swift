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
}
