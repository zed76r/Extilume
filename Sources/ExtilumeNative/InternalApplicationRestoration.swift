import ExtilumeCore
import Foundation

func verifyInternalApplicationRestoration(
    directory: URL,
    expectation: InternalApplicationExpectation?,
    requiresGuardProof: Bool,
    expectedRecord: RecoveryRecord? = nil,
    snapshotReader: () throws -> Snapshot = freshSnapshot,
    internalReader: (UUID, UInt32, InternalDisplayHardwareIdentity?) throws -> InternalDisplayState = {
        try freshInternalDisplay(identity: $0, numericIDHint: $1, hardwareIdentity: $2)
    }
) throws -> RecoveryRecord? {
    let store = try RecoveryStore(directory: directory)
    try store.acquireExclusiveOwnership()
    let record = try store.load()
    guard expectedRecord == nil || record == expectedRecord else { throw RecoveryError.unfinishedTransaction }
    guard let expectation else {
        guard record == nil else { throw RecoveryError.unfinishedTransaction }
        return nil
    }
    let baseline = expectation.baseline
    guard let record, expectation.matchesRestoredRecord(record),
          !requiresGuardProof || record.independentGuardVerified == true else {
        throw RecoveryError.unfinishedTransaction
    }
    let snapshot = try snapshotReader()
    guard try snapshot.layout() == baseline,
          let builtIn = snapshot.displays.first(where: { $0.identity == .builtIn }),
          builtIn.identityUUID == expectation.internalIdentity,
          builtIn.isOnline, builtIn.isActive else { throw RecoveryError.unresolvedSource }
    let hardware = expectation.hardware
    let internalState = try internalReader(expectation.internalIdentity, builtIn.id, hardware)
    guard internalState.matches(identity: expectation.internalIdentity, hardwareIdentity: hardware),
          internalState.isEnabled,
          try snapshotReader().layout() == baseline,
          try store.load() == record else { throw RecoveryError.unfinishedTransaction }
    return record
}
