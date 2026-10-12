import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private struct GuardReply: Codable { let ready: ProtectionHandshake }
private enum GuardCommand: String, Codable { case quiesce }
private enum GuardError: Error { case spawn, identity, missingRecord, protectionLost }

func spawnProbe(_ arguments: [String], channel: GuardChannel) throws -> pid_t {
    let inheritedDescriptor: Int32 = 198
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw GuardError.spawn }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        guard posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0 else { throw GuardError.spawn }
    }
    guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, inheritedDescriptor) == 0 else {
        throw GuardError.spawn
    }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw GuardError.spawn }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
        throw GuardError.spawn
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let strings = ([executable] + arguments + [String(inheritedDescriptor)]).map { strdup($0)! }
    defer { strings.forEach { free($0) } }
    var arguments: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    var child: pid_t = 0
    let result = arguments.withUnsafeMutableBufferPointer {
        posix_spawn(&child, executable, &actions, &attributes, $0.baseAddress!, environ)
    }
    guard result == 0, child > 1 else { throw GuardError.spawn }
    return child
}

/// 此演练只验证进程与责任协议，不调用任何显示配置写 API。
final class GuardDrill: @unchecked Sendable {
    private let directory: URL
    private let store: RecoveryStore
    private let queue = DispatchQueue(label: "Extilume.guard-drill")
    private var record: RecoveryRecord?
    private var channel: GuardChannel?
    private var child: pid_t = 0
    private var deathSource: DispatchSourceProcess?
    private var signals: [DispatchSourceSignal] = []
    private var authorization = ProtectionAuthorization()
    private var stopping = false

    init(directory: URL) throws {
        self.directory = directory
        store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
    }

    func start() throws {
        try queue.sync {
            guard try store.load() == nil else { throw RecoveryError.unfinishedTransaction }
            let baseline = try freshSnapshot().layout()
            let prepared = try RecoveryRecord(baseline: baseline, target: baseline)
            do {
                record = try store.apply(prepared) {
                    guard let durable = try store.load() else { throw GuardError.missingRecord }
                    let contract = try ProtectionHandshake(session: durable.session, generation: durable.generation, parentPID: getpid())
                    let parentChannel: GuardChannel = try {
                        let pair = try GuardChannel.pair()
                        child = try spawnProbe(["--display-guard", directory.path], channel: pair.1)
                        return pair.0
                    }()
                    channel = parentChannel
                    let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
                    source.setEventHandler { [weak self] in
                        guard let self else { return }
                        self.authorization.markLost()
                        var status: Int32 = 0
                        _ = waitpid(self.child, &status, WNOHANG)
                        if !self.stopping {
                            print("辅助进程失效；禁止新控制，主进程核验并收束演练。")
                            self.stop()
                        }
                    }
                    deathSource = source
                    source.resume()
                    try parentChannel.send(contract)
                    let reply = try parentChannel.receive(GuardReply.self)
                    try authorization.acknowledge(receipt: reply.ready, expected: contract)
                    guard try !parentChannel.peerClosed(), kill(child, 0) == 0 else {
                        authorization.markLost()
                        throw GuardError.protectionLost
                    }
                    try authorization.authorize(record: durable)
                    return (try freshSnapshot().layout(), nil)
                }
            } catch {
                record = try store.load()
                // 子进程已启动时须随主进程退出继续核验，不能杀掉保护来掩盖握手失败。
                throw error
            }
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.stop() }
                signals.append(source)
                source.resume()
            }
            print("不改显示设置的保护演练已就绪；输入 status / stop / crash / lose-guard。")
        }
        DispatchQueue.global().async { [weak self] in
            while let command = readLine() {
                self?.command(command.trimmingCharacters(in: .whitespaces))
            }
            self?.command("stop")
        }
    }

    private func command(_ command: String) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            switch command {
            case "status": print("主进程仍在运行；保护就绪=\(self.authorization.ready)；责任尚未独立清除。")
            case "stop": self.stop()
            case "crash": _exit(99)
            case "lose-guard": _ = kill(self.child, SIGKILL)
            default: print("有效命令：status / stop / crash / lose-guard。")
            }
        }
    }

    private func stop() {
        stopping = true
        do {
            guard var latest = try store.load(), let record, latest.session == record.session else {
                throw GuardError.missingRecord
            }
            latest.beginRestoration()
            try store.save(latest)
            try latest.confirmRestored(actual: freshSnapshot().layout())
            try store.save(latest)
            if authorization.ready {
                do { try channel?.send(GuardCommand.quiesce) }
                catch {
                    authorization.markLost()
                    print("辅助进程失效；禁止新控制，已核验的恢复结果仍保留。")
                }
            }
            print("主进程核验完成；辅助进程将等待主进程退出后独立读回，记录暂不清除。")
            exit(EXIT_SUCCESS)
        } catch {
            print("演练核验未完成；保留责任，辅助进程继续等待退出。")
            exit(EXIT_FAILURE)
        }
    }
}

final class DisplayGuard: @unchecked Sendable {
    private let channel: GuardChannel
    private let store: RecoveryStore
    private let contract: ProtectionHandshake
    private let queue = DispatchQueue(label: "Extilume.display-guard")
    private var parentSource: DispatchSourceProcess?
    private var inputSource: DispatchSourceRead?
    private var parentExited = false
    private var attemptCount = 0
    private var notificationAt: UInt64?

    init(directory: URL, descriptor: Int32) throws {
        channel = try GuardChannel(descriptor: descriptor)
        contract = try channel.receive(ProtectionHandshake.self)
        guard getppid() == contract.parentPID, kill(contract.parentPID, 0) == 0 else { throw GuardError.identity }
        store = try RecoveryStore(directory: directory)
        guard let record = try store.load(), contract.accepts(record: record),
              record.phase == .applying, !record.sourceUnresolved,
              record.baseline == record.applied, record.internalDisplay == nil else { throw GuardError.missingRecord }
    }

    func start() throws {
        try queue.sync {
        let source = DispatchSource.makeProcessSource(identifier: contract.parentPID, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.parentExited else { return }
            self.parentExited = true
            self.notificationAt = try? ContinuousClock.nanoseconds()
            self.inputSource?.cancel()
            self.attemptRecovery()
        }
        parentSource = source
        source.resume()
        let input = DispatchSource.makeReadSource(fileDescriptor: channel.descriptor, queue: queue)
        input.setEventHandler { [weak self] in
            guard let self, !self.parentExited else { return }
            do {
                if try self.channel.peerClosed() {
                    self.inputSource?.cancel()
                    return // EOF 不代替父进程退出；父进程仍可能持锁并正在恢复。
                }
                let command = try self.channel.receive(GuardCommand.self)
                if command == .quiesce {
                    print("辅助进程收到停止接管通知；继续保护到主进程实际退出。")
                    self.inputSource?.cancel()
                }
            } catch { self.inputSource?.cancel() }
        }
        inputSource = input
        input.resume()
        guard getppid() == contract.parentPID, kill(contract.parentPID, 0) == 0, try !channel.peerClosed() else {
            throw GuardError.identity
        }
        try channel.send(GuardReply(ready: contract))
        }
    }

    private func attemptRecovery() {
        do {
            try store.acquireExclusiveOwnership()
            guard var record = try store.load(), contract.accepts(record: record),
                  record.baseline == record.applied, record.internalDisplay == nil else {
                throw GuardError.missingRecord
            }
            let actual = try freshSnapshot().layout()
            guard actual == record.baseline else { throw RecoveryError.unfinishedTransaction }
            if !record.canClear {
                record.beginRestoration()
                try store.save(record)
                try record.confirmRestored(actual: actual)
                try store.save(record)
            }
            let elapsed = try ContinuousClock.nanoseconds() - (notificationAt ?? 0)
            print("辅助进程在主进程退出后独立读取并核验完成；通知至核验=\(elapsed / 1_000_000) ms。该值不代表实际故障至恢复时限。")
            exit(EXIT_SUCCESS)
        } catch {
            attemptCount += 1
            if attemptCount == 1 { print("辅助进程尚未核验恢复；保留责任，不提前退出。") }
            // shortcut: 尚未接入物理事件；仅未决演练按退避重试，真实停用前改为设备事件与有界恢复重试。
            let delay = min(30.0, 0.1 * pow(2.0, Double(min(attemptCount, 9))))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attemptRecovery() }
        }
    }
}
