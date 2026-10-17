import ExtilumeCore
import Foundation

// 操作可能已经写入；保护丢失时，仍存活的调用者必须接管恢复，不能直接退出。
func applyProtectedInternalRecord(
    store: RecoveryStore,
    prepared: RecoveryRecord,
    operation: (RecoveryRecord) throws -> (layout: DisplayLayout, internalEnabled: Bool?),
    recoverOnFailure: (RecoveryRecord) -> Void
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
        recoverOnFailure(applying)
        return nil
    }
}

func performProtectedInternalDisable(
    record: RecoveryRecord,
    loadRecord: () throws -> RecoveryRecord?,
    disable: (RecoveryRecord) throws -> Void,
    activeSnapshotReader: () throws -> Snapshot,
    internalReader: (UUID) throws -> InternalDisplayState,
    checkProtection: (RecoveryRecord) throws -> Void
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
    return (layout, false)
}
