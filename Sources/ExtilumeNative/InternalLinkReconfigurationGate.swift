import CoreGraphics
import ExtilumeCore
import Foundation

// 短锁只保护消息状态；预算回调不能依赖观察或原生控制队列。
final class InternalLinkReconfigurationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = InternalLinkReconfiguration()
    private var timer: DispatchSourceTimer?
    private var token: UUID?
    private let budget: UInt64 = 10_000_000_000
    private let now: @Sendable () throws -> UInt64
    private let onTimeout: @Sendable (UInt64) -> Void

    init(now: @escaping @Sendable () throws -> UInt64 = ContinuousClock.nanoseconds,
         onTimeout: @escaping @Sendable (UInt64) -> Void) {
        self.now = now
        self.onTimeout = onTimeout
    }

    var phase: InternalLinkReconfiguration.Phase { lock.withLock { state.phase } }

    typealias NativeCompletion = (result: CGError, startedAt: UInt64, returnedAt: UInt64)
    enum Failure: Error { case invalidWindow }

    deinit { timer?.cancel() }

    func prepare(candidates: [UInt64: ExternalConnectionService]) -> Bool {
        lock.withLock {
            guard state.prepare(candidates: candidates) else { return false }
            token = UUID()
            return true
        }
    }

    func consume(entryID: UInt64, messageType: UInt32, argument: ConnectionObservedArgument, at: UInt64) -> Bool {
        lock.withLock {
            guard state.phase == .collecting,
                  state.consume(entryID: entryID, messageType: messageType, argument: argument, at: at) else { return false }
            if timer == nil, let token, let first = state.firstPendingAt {
                let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                let elapsed = (try? now()).flatMap { $0 >= first ? $0 - first : nil }
                let remaining = elapsed.map { $0 < budget ? budget - $0 : 0 } ?? 0
                source.schedule(deadline: .now() + .nanoseconds(Int(remaining)))
                source.setEventHandler { [weak self] in self?.expire(token: token) }
                timer = source
                source.resume()
            }
            return true
        }
    }

    // 此处到原生函数之间以及返回到关闭之间均不能加入日志、排队或 I/O。
    func performNative(_ call: () -> CGError) throws -> NativeCompletion {
        let began = try now()
        guard lock.withLock({ state.begin(at: began) }) else { throw Failure.invalidWindow }
        let result = call()
        let ended = try now()
        guard lock.withLock({ state.endNative(succeeded: result == .success, at: ended) }) else {
            throw Failure.invalidWindow
        }
        return (result, began, ended)
    }

    func verify(at: UInt64) -> Bool {
        lock.withLock {
            guard state.verify(at: at) else { return false }
            cancelLocked()
            return true
        }
    }

    func fail() -> UInt64? {
        lock.withLock {
            let first = state.fail()
            cancelLocked()
            return first
        }
    }

    func invalidate(observedAt: UInt64?) -> UInt64? {
        let pending = fail()
        return observedAt.map { observed in pending.map { min($0, observed) } ?? observed }
    }

    private func cancelLocked() {
        timer?.cancel()
        timer = nil
        token = nil
    }

    private func expire(token: UUID) {
        let expired = lock.withLock { () -> UInt64? in
            guard self.token == token, state.isPending, let first = state.firstPendingAt else { return nil }
            if let current = try? now(), current >= first, current - first < budget {
                timer?.schedule(deadline: .now() + .nanoseconds(Int(budget - (current - first))))
                return nil
            }
            _ = state.fail()
            cancelLocked()
            return first
        }
        if let expired { onTimeout(expired) }
    }
}
