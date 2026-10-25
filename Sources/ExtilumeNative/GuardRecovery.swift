import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation
import Dispatch

extension Snapshot {
    func canonicalizingInternalDisplay(
        identity: UUID, hardwareIdentity: InternalDisplayHardwareIdentity,
        state: InternalDisplayState
    ) throws -> Snapshot {
        let builtIns = displays.indices.filter { displays[$0].identity == .builtIn }
        guard builtIns.count == 1, let index = builtIns.first,
              state.matches(identity: identity, hardwareIdentity: hardwareIdentity),
              let reported = state.reportedIdentityUUID,
              displays[index].id == state.id,
              displays[index].identityUUID == reported,
              displays[index].isOnline == state.isOnline,
              displays[index].isActive == state.isActive,
              Set(displays.map(\.id)).count == displays.count,
              displays.indices.filter({ $0 != index }).allSatisfy({
                  displays[$0].identityUUID != reported && displays[$0].identityUUID != identity
              }) else { throw RecoveryError.identityConflict }
        var result = displays
        result[index].identityUUID = identity
        return Snapshot(displays: result)
    }

    func internalDisplayState(identity: UUID) throws -> InternalDisplayState {
        let display = try builtInDisplay(identity: identity)
        return InternalDisplayState(
            id: display.id, identityUUID: identity, isBuiltIn: true,
            isOnline: display.isOnline, isActive: display.isActive
        )
    }

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

func freshGuardSnapshot(
    responsibility: InternalDisplayResponsibility?, numericIDHint: UInt32?,
    diagnosticRole: InternalLifecycleRole = .controller
) throws -> Snapshot {
    let snapshot = try freshSnapshot()
    guard let responsibility, let hardware = responsibility.hardwareIdentity else { return snapshot }
    guard let id = snapshot.displays.first(where: { $0.identity == .builtIn })?.id ?? numericIDHint else {
        throw RecoveryError.identityConflict
    }
    let state = try freshInternalDisplay(identity: responsibility.identity, numericIDHint: id,
                                        hardwareIdentity: hardware, diagnosticRole: diagnosticRole)
    return try snapshot.canonicalizingInternalDisplay(identity: responsibility.identity, hardwareIdentity: hardware, state: state)
}

// 重启后的显式恢复入口；数字 ID 仅用于找到候选，身份仍由独立观测重新核验。
func recoverInternalRecord(directory: URL) throws {
    let store = try RecoveryStore(directory: directory)
    try store.acquireExclusiveOwnership()
    guard let record = try store.load(), let responsibility = record.internalDisplay, responsibility.baseline else {
        throw RecoveryError.invalidRecord
    }
    let powerGate = InternalPowerGate()
    let wake = DispatchSemaphore(value: 0)
    let observer = InternalSystemPowerObserver(
        prepareForSleep: { powerGate.willSleep() },
        didPrepareForSleep: { accepted, acknowledged in
            if accepted { powerGate.didAcknowledgeSleep(acknowledged) }
            wake.signal()
        },
        didWake: { powerGate.didWake(); wake.signal() },
        onFailure: { powerGate.invalidate(); wake.signal() }
    )
    try observer.start()
    defer { observer.stop() }
    powerGate.didRegister()
    let contract = try ProtectionHandshake(
        session: record.session, generation: record.generation, parentPID: getpid(),
        internalDisplayIdentity: responsibility.identity, internalDisplayHardwareIdentity: responsibility.hardwareIdentity
    )
    let transaction = try DisplayEnableTransaction()
    while true {
        do {
            try powerGate.check()
            let hint: UInt32
            if let saved = responsibility.numericIDHint {
                hint = saved
            } else {
                hint = try freshActiveSnapshot().builtInDisplay(identity: responsibility.identity).id
            }
            _ = try recoverGuardRecord(
                store: store, contract: contract,
                snapshotReader: { try freshGuardSnapshot(responsibility: responsibility, numericIDHint: hint,
                                                        diagnosticRole: .recoveryEntry) },
                internalReader: { try freshInternalDisplay(identity: $0, numericIDHint: hint,
                                                          hardwareIdentity: responsibility.hardwareIdentity,
                                                          diagnosticRole: .recoveryEntry) },
                enableInternal: { restoring in
                    try transaction.enableInternalForRecovery(
                        record: restoring, loadRecord: { try store.load() },
                        trace: { traceInternalLifecycle($0, role: .recoveryEntry, cgError: $1) },
                        nativeCall: { try powerGate.perform($0) },
                        internalReader: {
                            try powerGate.check()
                            return try freshInternalDisplay(identity: $0, numericIDHint: hint,
                                                            hardwareIdentity: responsibility.hardwareIdentity,
                                                            diagnosticRole: .recoveryEntry)
                        }
                    )
                },
                originWriter: { _, origins in try configureOrigins(origins, option: .forSession, nativeCall: { try powerGate.perform($0) }) },
                layoutRejected: { traceInternalLifecycle(.layoutRestoreRejected, role: .recoveryEntry, succeeded: false, recoveryLayout: $0) },
                trace: { traceInternalLifecycle($0, role: .recoveryEntry) },
                checkAccess: { try powerGate.check() }
            )
            if powerGate.beginExitAfterRecovery() { return }
        } catch InternalPowerGateError.suspended {
            // 责任和独占归属跨休眠保留；电源队列继续及时确认。
        }
        wake.wait()
    }
}

// 调用者须持有目录独占锁；成功仅保存已恢复责任，不清除记录。
func recoverGuardRecord(
    store: RecoveryStore,
    contract: ProtectionHandshake,
    snapshotReader: () throws -> Snapshot,
    internalReader: (UUID) throws -> InternalDisplayState,
    enableInternal: (RecoveryRecord) throws -> Void,
    originWriter: (RecoveryRecord, [UInt32: DisplayOrigin]) throws -> Void,
    layoutRejected: (InternalRecoveryLayoutContext) -> Void = { _ in },
    trace: (InternalLifecycleStage) -> Void = { _ in },
    checkAccess: () throws -> Void = {}
) throws -> RecoveryRecord {
    try checkAccess()
    trace(.restorationStarted)
    func readInternal(_ identity: UUID) throws -> InternalDisplayState {
        try checkAccess()
        trace(.internalReadStarted)
        let state = try internalReader(identity)
        try checkAccess()
        trace(.internalReadFinished)
        return state
    }
    func readSnapshot() throws -> Snapshot {
        try checkAccess()
        trace(.layoutReadStarted)
        let snapshot = try snapshotReader()
        try checkAccess()
        trace(.layoutReadFinished)
        return snapshot
    }
    guard var record = try store.load(), contract.accepts(record: record) else {
        throw RecoveryError.identityConflict
    }
    if let responsibility = record.internalDisplay {
        guard responsibility.baseline else { throw RecoveryError.invalidRecord }
    } else {
        guard record.baseline == record.applied else { throw RecoveryError.invalidRecord }
    }

    var observedLayout: Snapshot?
    if record.phase == .owned, !record.sourceUnresolved, !record.layoutPending,
       let responsibility = record.internalDisplay, !responsibility.pending,
       responsibility.baseline, !responsibility.applied,
       record.applied.origins[responsibility.identity] == nil,
       let hardware = responsibility.hardwareIdentity {
        let before = try readSnapshot()
        observedLayout = before
        let current = try before.layout()
        if current == record.applied {
            let internalState = try readInternal(responsibility.identity)
            let candidate = try before.builtInDisplay(identity: responsibility.identity)
            guard internalState.matches(identity: responsibility.identity, hardwareIdentity: hardware),
                  candidate.id == internalState.id,
                  candidate.isOnline == internalState.isOnline,
                  candidate.isActive == internalState.isActive,
                  !internalState.isEnabled else { throw RecoveryError.identityConflict }
            var reappeared = record
            try reappeared.observe(current, source: .reconnect)
            try reappeared.observeInternalEnabled(false, source: .reconnect)
            try checkAccess()
            guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
            try store.save(reappeared)
            record = reappeared
            observedLayout = nil
        }
    }

    if !record.canClear {
        if record.phase != .restoring {
            try checkAccess()
            guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
            record.beginRestoration()
            try store.save(record)
        }
        if let responsibility = record.internalDisplay, responsibility.pending {
            let before = try readInternal(responsibility.identity)
            guard before.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity) else { throw RecoveryError.identityConflict }
            if !before.isEnabled {
                guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
                trace(.enableStarted)
                try enableInternal(record)
                trace(.enableFinished)
            }
            let enabled = try readInternal(responsibility.identity)
            guard enabled.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity), enabled.isEnabled else {
                throw RecoveryError.unfinishedTransaction
            }
        }
        let before = try observedLayout ?? readSnapshot()
        let current = try before.layout()
        let connected = try before.connected()
        if !record.sourceUnresolved || current != record.baseline {
            let plan: LayoutRestorePlan
            do { plan = try record.layoutRestorePlan(connected: connected, current: current) }
            catch {
                layoutRejected(InternalRecoveryLayoutContext(record: record, current: current))
                throw error
            }
            if !plan.origins.isEmpty {
                let fresh = try readSnapshot()
                guard try fresh.layout() == current,
                      try fresh.connected().count == connected.count,
                      try fresh.connected().allSatisfy({ connected.contains($0) }),
                      try store.load() == record else { throw RecoveryError.unfinishedTransaction }
                trace(.originsStarted)
                try originWriter(record, plan.origins)
                trace(.originsFinished)
            }
            guard plan.missing.isEmpty else { throw RecoveryError.unfinishedTransaction }
        }
    }

    let actual = try readSnapshot()
    let layout = try actual.layout()
    let internalEnabled: Bool? = try record.internalDisplay.map {
        let display = try readInternal($0.identity)
        guard display.matches(identity: $0.identity, hardwareIdentity: $0.hardwareIdentity) else { throw RecoveryError.identityConflict }
        return display.isEnabled
    }
    try checkAccess()
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
    trace(.restorationVerified)
    return record
}
