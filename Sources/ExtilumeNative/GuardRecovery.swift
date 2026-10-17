import CoreGraphics
import ExtilumeCore
import Foundation

extension Snapshot {
    func builtInDisplay(identity: UUID) throws -> DisplayState {
        let matches = displays.filter { $0.identityUUID == identity }
        guard matches.count == 1, let display = matches.first, display.identity == .builtIn,
              display.id != kCGNullDirectDisplay,
              displays.filter({ $0.id == display.id }).count == 1 else {
            throw RecoveryError.identityConflict
        }
        return display
    }
}

// 调用者须持有目录独占锁；成功仅保存已恢复责任，不清除记录。
func recoverGuardRecord(
    store: RecoveryStore,
    contract: ProtectionHandshake,
    snapshotReader: () throws -> Snapshot,
    enableInternal: (RecoveryRecord) throws -> Void,
    originWriter: ([UInt32: DisplayOrigin]) throws -> Void
) throws -> RecoveryRecord {
    guard var record = try store.load(), contract.accepts(record: record) else {
        throw RecoveryError.identityConflict
    }
    if let responsibility = record.internalDisplay {
        guard responsibility.baseline else { throw RecoveryError.invalidRecord }
    } else {
        guard record.baseline == record.applied else { throw RecoveryError.invalidRecord }
    }

    if !record.canClear {
        if record.phase != .restoring {
            record.beginRestoration()
            try store.save(record)
        }
        if let responsibility = record.internalDisplay, responsibility.pending {
            let before = try snapshotReader().builtInDisplay(identity: responsibility.identity)
            if !before.isOnline || !before.isActive {
                guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
                try enableInternal(record)
            }
            let enabled = try snapshotReader().builtInDisplay(identity: responsibility.identity)
            guard enabled.isOnline && enabled.isActive else { throw RecoveryError.unfinishedTransaction }
        }
        let before = try snapshotReader()
        let current = try before.layout()
        let connected = try before.connected()
        let plan = try record.layoutRestorePlan(connected: connected, current: current)
        if !plan.origins.isEmpty {
            let fresh = try snapshotReader()
            guard try fresh.layout() == current,
                  try fresh.connected().count == connected.count,
                  try fresh.connected().allSatisfy({ connected.contains($0) }),
                  try store.load() == record else { throw RecoveryError.unfinishedTransaction }
            try originWriter(plan.origins)
        }
        guard plan.missing.isEmpty else { throw RecoveryError.unfinishedTransaction }
    }

    let actual = try snapshotReader()
    let layout = try actual.layout()
    let internalEnabled: Bool? = try record.internalDisplay.map {
        let display = try actual.builtInDisplay(identity: $0.identity)
        return display.isOnline && display.isActive
    }
    guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
    if record.canClear {
        guard layout == record.baseline,
              record.internalDisplay.map({ internalEnabled == $0.baseline }) ?? true else {
            throw RecoveryError.unfinishedTransaction
        }
    } else {
        try record.confirmRestored(actual: layout, internalEnabled: internalEnabled)
        try store.save(record)
    }
    return record
}
