import CoreGraphics
import ExtilumeCore
import Foundation

// 原型入口独占状态目录；产品接入须先通过独立硬件门。
final class ExternalDisplayVerification {
    private let store: RecoveryStore
    private let snapshot: () throws -> Snapshot
    private let topology: () throws -> Snapshot
    private let external: (ExternalDisplayIdentity, UInt32) throws -> ExternalDisplayState
    private let capture: (UInt32) throws -> ExternalDisplayState
    private let lidIsOpen: () -> Bool
    private let transaction: () throws -> DisplayEnableTransaction
    private let writeOrigins: ([UInt32: DisplayOrigin], @escaping () throws -> Void) throws -> Void
    private let nativeCall: DisplayEnableTransaction.NativeCall
    private let checkAccess: () throws -> Void

    init(directory: URL, recoveryStore: RecoveryStore? = nil,
         snapshot: @escaping () throws -> Snapshot = { try freshActiveSnapshot() },
         topology: @escaping () throws -> Snapshot = { try freshSnapshot() },
         external: @escaping (ExternalDisplayIdentity, UInt32) throws -> ExternalDisplayState = {
             try freshExternalDisplay(identity: $0, numericIDHint: $1)
         },
         capture: @escaping (UInt32) throws -> ExternalDisplayState = {
             guard let state = try readExternalDisplayState($0) else { throw RecoveryError.identityConflict }
             return state
         },
         lidIsOpen: @escaping () -> Bool = { clamshellState() == "开盖" },
         transaction: @escaping () throws -> DisplayEnableTransaction = { try DisplayEnableTransaction() },
         writeOrigins: @escaping ([UInt32: DisplayOrigin], @escaping () throws -> Void) throws -> Void = {
             try configureOrigins($0, option: .forSession, validateBeforeCommit: $1)
         },
         nativeCall: @escaping DisplayEnableTransaction.NativeCall = { $0() },
         checkAccess: @escaping () throws -> Void = {}) throws {
        store = try recoveryStore ?? RecoveryStore(directory: directory)
        self.snapshot = snapshot
        self.topology = topology
        self.external = external
        self.capture = capture
        self.lidIsOpen = lidIsOpen
        self.transaction = transaction
        self.writeOrigins = writeOrigins
        self.checkAccess = checkAccess
        self.nativeCall = nativeCall
    }

    func status() throws -> String {
        guard let record = try store.load(), let responsibility = record.externalDisplay else {
            return "没有外屏责任；未写显示配置。"
        }
        let actual = try external(responsibility.identity, responsibility.numericIDHint)
        let current = try snapshot()
        let internalActive = current.displays.filter { $0.identity == .builtIn && $0.isOnline && $0.isActive }.count == 1
        return "外屏目标已重认；外屏活动=\(actual.isEnabled)，内屏活动=\(internalActive)，待恢复=\(record.requiresRecovery)。未写显示配置；PC 画面须人工确认。"
    }

    func disable(beforeDisable: (ExternalDisplayIdentity) -> Void = { _ in }) throws {
        try store.acquireExclusiveOwnership()
        var previous = try store.load()
        if let settled = previous, settled.canClear, settled.externalDisplay != nil {
            try restoreLocked()
            try store.clear()
            previous = nil
        }
        if let previous {
            guard previous.externalDisplay != nil, previous.internalDisplay == nil,
                  previous.phase == .owned, !previous.sourceUnresolved else { throw RecoveryError.unfinishedTransaction }
        }
        try checkAccess()
        let before = try topology()
        guard before.assessment.isSupported, before.displays.count == 2, lidIsOpen(),
              let internalDisplay = before.displays.first(where: { $0.identity == .builtIn && $0.isOnline && $0.isActive }),
              let internalID = internalDisplay.identityUUID,
              let display = before.displays.first(where: { $0.identity == .physical }) else {
            throw DisplayEnableTransactionError.unsafeTopology
        }
        let target = try capture(display.id)
        guard target.id == display.id, target.identity.uuid == display.identityUUID, target.isEnabled else {
            throw RecoveryError.identityConflict
        }
        let baseline = try before.layout()
        let record: RecoveryRecord
        if var prior = previous {
            guard prior.externalDisplay?.identity == target.identity else { throw RecoveryError.identityConflict }
            if baseline == prior.baseline { try prior.observe(baseline, source: .reconnect) }
            try prior.prepareReapplication(current: baseline, target: layoutByMakingMain(baseline, target: internalID))
            record = prior
        } else {
            record = try RecoveryRecord(
                baseline: baseline, target: layoutByMakingMain(baseline, target: internalID),
                externalDisplay: ExternalDisplayResponsibility(identity: target.identity, numericIDHint: target.id,
                                                               baseline: true, applied: false)
            )
        }
        beforeDisable(target.identity)
        let writer = try transaction()
        do {
            _ = try store.applyExternal(record, beforeOperation: checkAccess) {
                guard let applying = try self.store.load() else { throw RecoveryError.invalidRecord }
                try writer.disableExternal(record: applying, loadRecord: self.store.load,
                                           snapshotReader: self.topology,
                                           externalReader: { try self.external(target.identity, target.id) },
                                           lidIsOpen: self.lidIsOpen, checkAccess: self.checkAccess, nativeCall: self.nativeCall)
                let observed = try self.external(target.identity, target.id)
                let actual = try self.snapshot()
                guard actual.displays.count == 1, actual.displays.first?.identity == .builtIn,
                      actual.displays.first?.isOnline == true, actual.displays.first?.isActive == true,
                      actual.displays.first?.identityUUID == internalID,
                      !observed.isActive else { throw RecoveryError.unresolvedSource }
                return (layout: try actual.layout(), internalEnabled: true as Bool?, externalEnabled: false as Bool?)
            }
        } catch {
            let failure = error
            // 一旦可能进入原生写入，失败也保留责任；补偿失败不得清理记录。
            if let pending = try? store.load(), pending.requiresRecovery { try? restoreLocked() }
            throw failure
        }
    }

    func reconcile(allowReapplication: Bool) throws -> PrimarySessionStatus {
        try store.acquireExclusiveOwnership()
        guard var record = try store.load(), let responsibility = record.externalDisplay,
              record.internalDisplay == nil else { throw RecoveryError.invalidRecord }
        try checkAccess()
        let target = try external(responsibility.identity, responsibility.numericIDHint)
        let actual = try snapshot()
        let internals = actual.displays.filter { $0.identity == .builtIn && $0.isOnline && $0.isActive }
        guard internals.count == 1, lidIsOpen() else {
            try restoreLocked()
            return .manualConfiguration
        }
        if record.canClear || (!responsibility.pending && responsibility.applied) {
            try restoreLocked()
            return .manualConfiguration
        }
        if !target.isActive {
            guard actual.displays.count == 1, try actual.layout() == record.applied,
                  !record.sourceUnresolved else {
                if record.phase == .applying, !record.sourceUnresolved {
                    try record.confirmApplied(actual.layout(), internalEnabled: true, externalEnabled: false)
                    try checkAccess()
                    try store.save(record)
                    return .applied
                }
                throw RecoveryError.unfinishedTransaction
            }
            guard record.phase == .owned else { throw RecoveryError.unfinishedTransaction }
            return .applied
        }
        guard record.phase == .owned, !record.sourceUnresolved else { throw RecoveryError.unfinishedTransaction }
        if allowReapplication {
            try checkAccess()
            try disable()
            return .applied
        }
        do { try record.observeExternalEnabled(true, source: .unknown) }
        catch {
            try checkAccess()
            try store.save(record)
            throw error
        }
        throw RecoveryError.unresolvedSource
    }

    func hasRecord() throws -> Bool { try store.load() != nil }
    func targetIdentity() throws -> ExternalDisplayIdentity? { try store.load()?.externalDisplay?.identity }

    func confirmUserLayout() throws {
        guard var record = try store.load(), record.externalDisplay != nil else { throw RecoveryError.invalidRecord }
        let current = try topology()
        guard current.assessment.isSupported else { throw RecoveryError.unresolvedSource }
        let responsibility = record.externalDisplay!
        guard try external(responsibility.identity, responsibility.numericIDHint).isEnabled else {
            throw RecoveryError.unresolvedSource
        }
        guard try topology() == current else { throw RecoveryError.unresolvedSource }
        let internalActive = current.displays.filter { $0.identity == .builtIn && $0.isOnline && $0.isActive }.count == 1
        try record.confirmExternalUserLayout(current.layout(), internalEnabled: internalActive, externalEnabled: true)
        try checkAccess()
        try store.save(record)
    }

    func restore() throws {
        try store.acquireExclusiveOwnership()
        try restoreLocked()
    }

    private func restoreLocked() throws {
        guard var record = try store.load(), let responsibility = record.externalDisplay,
              record.internalDisplay == nil else { throw RecoveryError.invalidRecord }
        try checkAccess()
        let target = try external(responsibility.identity, responsibility.numericIDHint)
        if record.canClear {
            guard target.isEnabled else { throw RecoveryError.unfinishedTransaction }
            let current = try topology()
            guard current.assessment.isSupported, current.displays.count == 2,
                  current.displays.filter({ $0.identity == .builtIn && $0.isOnline && $0.isActive }).count == 1,
                  current.displays.first(where: { $0.identity == .physical })?.identityUUID == responsibility.identity.uuid else {
                throw RecoveryError.unfinishedTransaction
            }
            let actual = try current.layout()
            guard Set(actual.origins.keys) == Set(record.baseline.origins.keys) else {
                throw RecoveryError.unfinishedTransaction
            }
            guard actual == record.baseline else { throw RecoveryError.unresolvedSource }
            return
        }
        record.beginRestoration()
        try store.save(record)
        if !target.isEnabled {
            try transaction().enableExternalForRecovery(
                record: record, loadRecord: store.load,
                externalReader: { try self.external(responsibility.identity, responsibility.numericIDHint) },
                checkAccess: checkAccess, nativeCall: nativeCall
            )
        }
        guard try external(responsibility.identity, responsibility.numericIDHint).isEnabled else {
            throw RecoveryError.unfinishedTransaction
        }
        let current = try snapshot()
        if try current.layout() != record.baseline {
            let plan = try record.layoutRestorePlan(connected: current.connected(), current: current.layout())
            guard plan.missing.isEmpty else { throw RecoveryError.identityConflict }
            let durable = record
            try writeOrigins(plan.origins) {
                try self.checkAccess()
                guard try self.store.load() == durable else { throw RecoveryError.unfinishedTransaction }
                guard try self.snapshot() == current,
                      try self.external(responsibility.identity, responsibility.numericIDHint).isEnabled else {
                    throw RecoveryError.unresolvedSource
                }
            }
        }
        let actual = try snapshot().layout()
        let enabled = try external(responsibility.identity, responsibility.numericIDHint).isEnabled
        let internalActive = try snapshot().displays.filter { $0.identity == .builtIn && $0.isOnline && $0.isActive }.count == 1
        try record.confirmRestored(actual: actual, internalEnabled: internalActive, externalEnabled: enabled)
        try store.save(record)
    }
}

enum ExternalVerificationCommand: Equatable {
    case status(String), disable(String), restore(String)

    init?(arguments: [String]) throws {
        guard let flag = arguments.first,
              ["--external-status", "--verify-external-disable", "--recover-external"].contains(flag) else { return nil }
        if flag == "--external-status" {
            guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else {
                throw ApplicationLaunchError.invalidArguments
            }
            self = .status(arguments[1])
        } else {
            guard arguments.count == 3, arguments[1] == "--allow-display-write",
                  !arguments[2].isEmpty, !arguments[2].hasPrefix("--") else {
                throw ApplicationLaunchError.invalidArguments
            }
            self = flag == "--verify-external-disable" ? .disable(arguments[2]) : .restore(arguments[2])
        }
    }
}

func runExternalVerification(_ command: ExternalVerificationCommand) throws {
    if case .status(let path) = command {
        print(try ExternalDisplayVerification(directory: URL(fileURLWithPath: path)).status())
        return
    }
    let gate = InternalPowerGate()
    let observer = InternalSystemPowerObserver(
        prepareForSleep: { gate.willSleep() },
        didPrepareForSleep: { accepted, acknowledged in
            if accepted { gate.didAcknowledgeSleep(acknowledged) }
        },
        didWake: { _ = gate.didWake() }, onFailure: { gate.invalidate() }
    )
    try observer.start()
    gate.didRegister()
    defer { gate.invalidate(); observer.stop() }
    let path: String
    switch command {
    case .disable(let value), .restore(let value): path = value
    case .status: return
    }
    let verifier = try ExternalDisplayVerification(
        directory: URL(fileURLWithPath: path),
        writeOrigins: { origins, validate in
            try configureOrigins(origins, option: .forSession, nativeCall: { try gate.perform($0) },
                                 validateBeforeCommit: validate)
        },
        nativeCall: { try gate.perform($0) }, checkAccess: { try gate.check() }
    )
    switch command {
    case .disable:
        try verifier.disable()
        print("外接屏已独立核验停用；请手动切到 PC。内屏交互和 PC 画面仍须人工确认。")
        print("会话保持中；status 只读核对，restore / stop 恢复后结束。")
        try holdExternalVerification(verifier)
    case .restore:
        try verifier.restore()
        print("Mac 外屏启用及布局已核验，责任记录保留；请手动切回 Mac 输入。")
    case .status: break
    }
}

func holdExternalVerification(
    _ verifier: ExternalDisplayVerification,
    readCommand: () -> String? = { readLine() },
    output: (String) -> Void = { print($0) }
) throws {
    while let line = readCommand() {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "status":
            do { output(try verifier.status()) }
            catch { output("读回未确认；保留责任，类别=\(snapshotWitnessFailureCode(error))。") }
        case "restore", "stop":
            do {
                try verifier.restore()
                output("Mac 配置已核验恢复；请手动切回 Mac 输入。责任记录保留。")
                return
            } catch {
                output("恢复未完成，尚未结束会话；请核对原屏并重试，类别=\(snapshotWitnessFailureCode(error))。")
            }
        default: output("命令：status、restore、stop。")
        }
    }
    // 输入结束同样先补偿；不能把管道关闭当作责任已结清。
    try verifier.restore()
}
