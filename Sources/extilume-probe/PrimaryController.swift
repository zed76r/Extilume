import AppKit
import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private enum PrimaryError: Error {
    case unsupported, unstable, transactionFailed, readbackMismatch, superseded
}

extension Snapshot {
    func layout() throws -> DisplayLayout {
        let active = displays.filter(\.isActive)
        guard let main = active.first(where: \.isMain)?.identityUUID,
              active.allSatisfy({ $0.identityUUID != nil && $0.isOnline && !$0.isMirrored }),
              Set(active.compactMap(\.identityUUID)).count == active.count else { throw PrimaryError.unsupported }
        var origins: [UUID: DisplayOrigin] = [:]
        for display in active {
            guard let identity = display.identityUUID,
                  let x = Int32(exactly: display.originX),
                  let y = Int32(exactly: display.originY) else { throw PrimaryError.unsupported }
            origins[identity] = DisplayOrigin(x: x, y: y)
        }
        return try DisplayLayout(main: main, origins: origins)
    }

    func connected() throws -> [ConnectedDisplay] {
        try displays.filter(\.isActive).map {
            guard let identity = $0.identityUUID else { throw PrimaryError.unsupported }
            return ConnectedDisplay(identity: identity, numericID: $0.id)
        }
    }
}

func stableSnapshot() throws -> Snapshot {
    var before = try readSnapshot()
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.1)
        let after = try readSnapshot()
        if before == after { return after }
        before = after
    }
    throw PrimaryError.unstable
}

private func configureOrigins(_ origins: [UInt32: DisplayOrigin], option: CGConfigureOption) throws {
    guard !origins.isEmpty else { return }
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        throw PrimaryError.transactionFailed
    }
    var completed = false
    defer { if !completed { CGCancelDisplayConfiguration(configuration) } }
    for (id, origin) in origins.sorted(by: { $0.key < $1.key }) {
        guard CGConfigureDisplayOrigin(configuration, id, origin.x, origin.y) == .success else {
            throw PrimaryError.transactionFailed
        }
    }
    let completion = CGCompleteDisplayConfiguration(configuration, option)
    completed = true // SDK 规定 Complete 返回后句柄无效，包括失败返回。
    guard completion == .success else {
        throw PrimaryError.transactionFailed
    }
}

// 所有状态仅由 queue 访问；系统回调与输入线程只负责入队。
final class PrimaryController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Extilume.primary")
    private let store: RecoveryStore
    private var record: RecoveryRecord?
    private var wakeObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var registered = false
    private var stopping = false
    private var transactions = 0
    private let reapplication: PrimaryReapplicationScheduler

    init(directory: URL) throws {
        reapplication = PrimaryReapplicationScheduler(ownerQueue: queue)
        store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
    }

    func recoverOnly() throws {
        try queue.sync {
            record = try store.load()
            guard record?.phase != .restored else { throw RecoveryError.unfinishedTransaction }
            if var pending = record, pending.sourceUnresolved {
                // 原进程已退出；完整基准的独立读回只解除责任，不生成补偿写入。
                guard pending.internalDisplay == nil,
                      try freshSnapshot().layout() == pending.baseline,
                      try freshSnapshot().layout() == pending.baseline else {
                    throw RecoveryError.unresolvedSource
                }
                pending.beginRestoration()
                try store.save(pending)
                try pending.confirmRestored(actual: pending.baseline)
                try store.save(pending)
                record = pending
                print("两个独立读回均为完整恢复基准；未写显示配置，记录保留待终验。")
                return
            }
            try restore()
        }
    }

    func confirmUserOnly() throws {
        try queue.sync {
            guard let pending = try store.load(), pending.phase == .owned else {
                throw RecoveryError.unfinishedTransaction
            }
            record = pending
            let snapshot = try freshSnapshot()
            guard try snapshot.layout() != pending.applied else { throw RecoveryError.unresolvedSource }
            try observe(source: .confirmedUser)
            guard record?.sourceUnresolved == false, record?.layoutPending == false else {
                throw RecoveryError.unresolvedSource
            }
            print("已按操作人员明确确认的 C 更新恢复基准；本命令未写入显示配置。")
        }
    }

    func finalizeOnly() throws {
        try queue.sync {
            guard let restored = try store.load(), restored.canClear, restored.internalDisplay == nil,
                  try freshSnapshot().layout() == restored.baseline else { throw RecoveryError.unfinishedTransaction }
            try store.clear()
            print("独立进程已读回恢复基准；本次责任记录已清除。")
        }
    }

    func start() throws {
        try queue.sync {
            guard try store.load() == nil else { throw RecoveryError.unfinishedTransaction }
            guard CGDisplayRegisterReconfigurationCallback(primaryDisplayCallback,
                Unmanaged.passUnretained(self).toOpaque()) == .success else { throw PrimaryError.unsupported }
            registered = true
            do { try apply() } catch {
                CGDisplayRemoveReconfigurationCallback(primaryDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
                registered = false
                throw error
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.wake() }
        queue.sync {
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.stop() }
                signals.append(source)
                source.resume()
            }
            print("主屏验证已启动；事务数=\(transactions)。输入 status / confirm-user / reapply / stop。")
        }
        DispatchQueue.global().async { [weak self] in
            while let command = readLine() { self?.command(command.trimmingCharacters(in: .whitespaces)) }
            self?.command("stop")
        }
    }

    func displayChanged(_ flags: CGDisplayChangeSummaryFlags) {
        let disconnected = !flags.intersection([.removeFlag, .disabledFlag]).isEmpty
        let connected = !flags.intersection([.addFlag, .enabledFlag]).isEmpty
        if flags != .desktopShapeChangedFlag { reapplication.invalidate() }
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            if flags.contains(.beginConfigurationFlag) {
                self.reapplication.cancel()
                return
            }
            if !disconnected && (connected || (flags == .desktopShapeChangedFlag && self.reapplication.hasPending)) {
                self.scheduleReapplication()
                return
            }
            // 用户设置或断开事件不能留下稍后覆盖 C 的旧接管意图。
            self.reapplication.cancel()
            do {
                try self.observe(source: disconnected ? .reconnect : .unknown)
            } catch {
                print("显示事件来源或拓扑未确认；保留责任，停止本次接管。")
            }
        }
    }

    private func wake() {
        reapplication.invalidate()
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.scheduleReapplication()
        }
    }

    private func scheduleReapplication() {
        reapplication.schedule { [weak self] isCurrent in
            guard let self, !self.stopping, isCurrent() else { return }
            do {
                try self.observe(source: .reconnect)
                guard isCurrent() else { return }
                try self.apply(isCurrent: isCurrent)
            }
            catch { print("连接或唤醒后未满足接管条件；保留责任，停止本次接管。") }
        }
    }

    private func command(_ command: String) {
        if ["confirm-user", "reapply", "stop"].contains(command) { reapplication.invalidate() }
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            do {
                switch command {
                case "status":
                    let snapshot = try freshSnapshot()
                    print("活动屏=\(snapshot.displays.filter(\.isActive).count)；HDMI 主屏=\(snapshot.displays.contains { $0.identity == .physical && $0.isMain })；事务数=\(self.transactions)；未决来源=\(self.record?.sourceUnresolved ?? false)。")
                case "confirm-user":
                    self.reapplication.cancel()
                    try self.observe(source: .confirmedUser)
                    print("已按操作人员的明确用户修改证据记录 C；尚未重新接管。")
                case "reapply": self.reapplication.cancel(); try self.apply()
                case "stop": self.stop()
                default: print("有效命令：status / confirm-user / reapply / stop。")
                }
            } catch { print("操作未完成；保留责任，不继续接管。") }
        }
    }

    private func observe(source: ConfigurationSource) throws {
        guard var record else { return }
        let snapshot = try freshSnapshot()
        let layout = try snapshot.layout()
        if source == .confirmedUser {
            guard record.phase == .owned, layout != record.applied else { throw RecoveryError.unresolvedSource }
        }
        do { try record.observe(layout, source: source) }
        catch { self.record = record; try store.save(record); throw error }
        self.record = record
        try store.save(record)
    }

    private func apply(isCurrent: @Sendable () -> Bool = { true }) throws {
        let snapshot = try freshSnapshot()
        guard isCurrent() else { throw PrimaryError.superseded }
        guard clamshellState() == "开盖", snapshot.assessment.isSupported,
              snapshot.displays.filter({ $0.identity == .builtIn && $0.isActive }).count == 1,
              snapshot.displays.filter(\.isActive).count == 2,
              let targetID = snapshot.displays.first(where: { $0.identity == .physical })?.identityUUID else {
            print("等待开盖、物理 HDMI 与稳定双屏非镜像桌面；未执行新控制，已有责任保留。")
            return
        }
        let current = try snapshot.layout()
        let target = try layoutByMakingMain(current, target: targetID)
        if let record, record.sourceUnresolved { throw RecoveryError.unresolvedSource }
        // 重复的连接及自身事件在 B 上不产生新的事务。
        guard target != current else { return }
        let prepared: RecoveryRecord
        if var existing = record {
            try existing.prepareReapplication(current: current, target: target)
            prepared = existing
        } else {
            prepared = try RecoveryRecord(baseline: current, target: target)
        }
        let mapping = try snapshot.connected()
        var origins: [UInt32: DisplayOrigin] = [:]
        for display in mapping { origins[display.numericID] = target.origins[display.identity] }
        var stage = "责任记录落盘"
        do {
            record = try store.apply(prepared, beforeOperation: {
                stage = "写入前独立读回"
                let immediatelyBefore = try freshSnapshot()
                guard isCurrent() else { throw PrimaryError.superseded }
                guard immediatelyBefore == snapshot else { throw PrimaryError.unstable }
            }) {
                stage = "公开坐标写入"
                try configureOrigins(origins, option: .forAppOnly)
                stage = "写入后目标读回"
                let after = try freshSnapshot().layout()
                guard after == target else { throw PrimaryError.readbackMismatch }
                stage = "应用确认与记录落盘"
                return (after, nil)
            }
            transactions += 1
            print("公开坐标事务已读回；事务数=\(transactions)。内屏仍须现场确认扩展桌面。")
        } catch {
            print("主屏事务未完成；失败阶段=\(stage)，责任记录保留。")
            record = try store.load()
            throw error
        }
    }

    private func restore() throws {
        guard var record else { print("没有本次待恢复记录。"); return }
        guard record.internalDisplay == nil else { throw RecoveryError.unfinishedTransaction }
        let snapshot = try freshSnapshot()
        let current = try snapshot.layout()
        let plan = try record.layoutRestorePlan(connected: snapshot.connected(), current: current)
        record.beginRestoration()
        self.record = record
        try store.save(record)
        // C 后直接退出也须提交当前 C，避免 forAppOnly 的退出回退覆盖它。
        let origins: [UInt32: DisplayOrigin]
        if record.baseline == record.applied, current == record.baseline {
            origins = [:] // 不改配置的保护演练只读回，不生成补偿事务。
        } else if !record.layoutPending {
            origins = Dictionary(uniqueKeysWithValues: try snapshot.connected().map { ($0.numericID, current.origins[$0.identity]!) })
        } else { origins = plan.origins }
        guard try freshSnapshot() == snapshot else { throw PrimaryError.unstable }
        try configureOrigins(origins, option: .forSession)
        let after = try freshSnapshot().layout()
        do { try record.confirmRestored(actual: after) }
        catch { self.record = record; try store.save(record); throw error }
        // 退出后独立观测才有权清除记录；进程内读回不能证明作用域退出结果。
        self.record = record
        try store.save(record)
        print("恢复提交与进程内读回完成；退出后须独立核对 C，责任记录保留。")
    }

    private func stop() {
        stopping = true
        reapplication.cancel()
        var success = true
        do { try restore() } catch { success = false; print("恢复未完成；保留未决责任。") }
        if registered { CGDisplayRemoveReconfigurationCallback(primaryDisplayCallback, Unmanaged.passUnretained(self).toOpaque()) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        signals.forEach { $0.cancel() }
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

private func primaryDisplayCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PrimaryController>.fromOpaque(context).takeUnretainedValue().displayChanged(flags)
}
