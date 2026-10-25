import Foundation

enum InternalPowerGateError: Error, Equatable {
    case suspended
    case unavailable
    case concurrentCall
}

final class InternalPowerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var sleeping = false
    private var pendingAcknowledgements = 0
    private var contextFailed = false
    private var exiting = false
    private var inFlightCall = false

    init() {}

    var isReady: Bool { (try? check()) != nil }

    func invalidate() {
        lock.lock()
        contextFailed = true
        lock.unlock()
    }

    func didRegister() {
        lock.lock()
        registered = true
        lock.unlock()
    }

    @discardableResult
    func willSleep() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exiting else { return false }
        sleeping = true
        if pendingAcknowledgements == Int.max {
            contextFailed = true
        } else {
            pendingAcknowledgements += 1
        }
        return true
    }

    func didAcknowledgeSleep(_ success: Bool) {
        lock.lock()
        if !success { contextFailed = true }
        if pendingAcknowledgements > 0 {
            pendingAcknowledgements -= 1
        } else {
            contextFailed = true
        }
        lock.unlock()
    }

    @discardableResult
    func didWake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasSleeping = sleeping
        sleeping = false
        return wasSleeping
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
    }

    func perform<T>(_ call: () throws -> T) throws -> T {
        lock.lock()
        do {
            try checkLocked()
            guard !inFlightCall else { throw InternalPowerGateError.concurrentCall }
            inFlightCall = true
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        defer {
            lock.lock()
            inFlightCall = false
            lock.unlock()
        }
        return try call()
    }

    func beginExitAfterRecovery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do { try checkLocked() }
        catch { return false }
        guard !inFlightCall else { return false }
        exiting = true
        return true
    }

    private func checkLocked() throws {
        guard registered, !contextFailed, !exiting else {
            throw InternalPowerGateError.unavailable
        }
        guard !sleeping, pendingAcknowledgements == 0 else {
            throw InternalPowerGateError.suspended
        }
    }
}
