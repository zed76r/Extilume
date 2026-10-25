import ExtilumeCore
import Foundation

private func protectedInternalSnapshot(
    _ snapshot: Snapshot, internalIdentity: UUID
) throws -> (layout: DisplayLayout, connected: [ConnectedDisplay], externalIdentity: UUID) {
    let builtIn = snapshot.displays.filter { $0.identity == .builtIn }
    let physical = snapshot.displays.filter { $0.identity == .physical }
    let identities = snapshot.displays.compactMap(\.identityUUID)
    guard snapshot.assessment.isSupported,
          snapshot.displays.count == 2,
          builtIn.count == 1, physical.count == 1,
          snapshot.displays.allSatisfy({ $0.isOnline && $0.isActive && !$0.isMirrored && $0.id != 0 && $0.identityUUID != nil }),
          Set(snapshot.displays.map(\.id)).count == 2,
          Set(identities).count == 2,
          snapshot.displays.filter(\.isMain).count == 1,
          builtIn.first?.identityUUID == internalIdentity,
          let externalIdentity = physical.first?.identityUUID,
          externalIdentity != internalIdentity else {
        throw DisplayEnableTransactionError.unsafeTopology
    }
    return (try snapshot.layout(), try snapshot.connected(), externalIdentity)
}

// 操作可能已经写入；保护丢失时，仍存活的调用者必须接管恢复，不能直接退出。
func applyProtectedInternalRecord(
    store: RecoveryStore,
    prepared: RecoveryRecord,
    operation: (RecoveryRecord) throws -> (layout: DisplayLayout, internalEnabled: Bool?),
    recoverOnFailure: (RecoveryRecord, Error) -> Void
) throws -> RecoveryRecord? {
    var applying: RecoveryRecord?
    do {
        return try store.apply(prepared) {
            guard let durable = try store.load() else { throw RecoveryError.unfinishedTransaction }
            applying = durable
            return try operation(durable)
        }
    } catch {
        guard let applying else { throw error }
        recoverOnFailure(applying, error)
        return nil
    }
}

func performProtectedInternalDisable(
    record: RecoveryRecord,
    loadRecord: () throws -> RecoveryRecord?,
    disable: (RecoveryRecord) throws -> Void,
    activeSnapshotReader: () throws -> Snapshot,
    internalReader: (UUID) throws -> InternalDisplayState,
    checkProtection: (RecoveryRecord) throws -> Void,
    verifyLinkReconfiguration: () throws -> Void = {}
) throws -> (layout: DisplayLayout, internalEnabled: Bool?) {
    try record.validate()
    guard record.phase == .applying, !record.sourceUnresolved,
          let responsibility = record.internalDisplay,
          responsibility.baseline, !responsibility.applied, responsibility.pending else {
        throw RecoveryError.invalidRecord
    }
    try checkProtection(record)
    guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
    try disable(record)
    print("内屏停用阶段：事务返回成功。")
    let actual = try activeSnapshotReader()
    let internalState = try internalReader(responsibility.identity)
    guard internalState.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity), !internalState.isActive,
          actual.displays.count == 1,
          let external = actual.displays.first,
          external.id != 0, external.identity == .physical, external.isActive, external.isOnline,
          external.isMain, !external.isMirrored,
          external.identityUUID == record.applied.main else {
        throw DisplayEnableTransactionError.unsafeTopology
    }
    let layout = try actual.layout()
    print("内屏停用阶段：独立效果读回完成，待保护复核。")
    guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
    try checkProtection(record)
    try verifyLinkReconfiguration()
    try checkProtection(record)
    return (layout, false)
}

func confirmProtectedInternalConfiguration(record: RecoveryRecord, snapshot: Snapshot) throws -> RecoveryRecord {
    try record.validate()
    guard record.phase == .owned,
          let responsibility = record.internalDisplay,
          responsibility.baseline, !responsibility.applied,
          responsibility.hardwareIdentity != nil else { throw RecoveryError.invalidRecord }
    let current = try protectedInternalSnapshot(snapshot, internalIdentity: responsibility.identity)
    var observed = record
    try observed.observe(current.layout, source: .confirmedUser)
    try observed.observeInternalEnabled(true, source: .confirmedUser)
    try observed.validate()
    return observed
}

func prepareProtectedInternalReapplication(record: RecoveryRecord, snapshot: Snapshot) throws -> RecoveryRecord {
    try record.validate()
    guard record.phase == .owned, !record.sourceUnresolved, !record.layoutPending,
          let responsibility = record.internalDisplay,
          responsibility.baseline, !responsibility.applied, !responsibility.pending,
          responsibility.hardwareIdentity != nil else {
        throw RecoveryError.invalidRecord
    }
    let current = try protectedInternalSnapshot(snapshot, internalIdentity: responsibility.identity)
    guard current.layout == record.baseline else { throw RecoveryError.unresolvedSource }
    let target = try layoutByMakingMain(current.layout, target: current.externalIdentity)
    var prepared = record
    try prepared.prepareReapplication(current: current.layout, target: target)
    return prepared
}

func translateProtectedInternalLayout(
    record: RecoveryRecord,
    loadRecord: @escaping () throws -> RecoveryRecord?,
    snapshotReader: @escaping () throws -> Snapshot,
    originWriter: ([UInt32: DisplayOrigin], () throws -> Void) throws -> Void,
    checkProtection: @escaping (RecoveryRecord) throws -> Void
) throws {
    try record.validate()
    guard record.phase == .applying, !record.sourceUnresolved,
          let responsibility = record.internalDisplay,
          responsibility.baseline, !responsibility.applied, responsibility.pending,
          responsibility.hardwareIdentity != nil else { throw RecoveryError.invalidRecord }
    guard Set(record.applied.origins.keys) == Set(record.baseline.origins.keys) else {
        throw RecoveryError.identityConflict
    }

    let before = try snapshotReader()
    let beforeState = try protectedInternalSnapshot(before, internalIdentity: responsibility.identity)
    guard beforeState.layout == record.baseline,
          Set(beforeState.connected.map(\.identity)) == Set(record.baseline.origins.keys) else {
        throw RecoveryError.unresolvedSource
    }
    guard record.applied == (try layoutByMakingMain(beforeState.layout, target: beforeState.externalIdentity)) else {
        throw RecoveryError.invalidRecord
    }

    func gate() throws {
        try checkProtection(record)
        guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        guard try snapshotReader() == before else { throw DisplayEnableTransactionError.unsafeTopology }
    }
    try gate()

    if record.baseline != record.applied {
        var origins: [UInt32: DisplayOrigin] = [:]
        for display in beforeState.connected {
            guard let origin = record.applied.origins[display.identity] else { throw RecoveryError.identityConflict }
            origins[display.numericID] = origin
        }
        guard origins.count == beforeState.connected.count else { throw RecoveryError.identityConflict }
        try originWriter(origins, gate)
    }

    let after = try protectedInternalSnapshot(
        snapshotReader(), internalIdentity: responsibility.identity
    )
    guard after.layout == record.applied else { throw DisplayEnableTransactionError.unsafeTopology }
    guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
    try checkProtection(record)
}
