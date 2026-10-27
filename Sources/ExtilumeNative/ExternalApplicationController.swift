import AppKit
import CoreGraphics
import ExtilumeCore
import Foundation

// 状态只在串行队列访问；请求与睡眠门禁能在独立读回阻塞期间撤销新写入。
final class ExternalApplicationController: @unchecked Sendable {
    typealias Factory = @Sendable (
        URL, RecoveryStore, @escaping () throws -> Void, @escaping DisplayEnableTransaction.NativeCall
    ) throws -> ExternalDisplayVerification

    private let queue = DispatchQueue(label: "Extilume.external-handoff")
    private let directory: URL
    private let store: RecoveryStore
    private let factory: Factory
    private let gate = InternalPowerGate()
    private let lock = NSLock()
    private var requestedEpoch = UUID()
    private var pendingAction: String?
    private var pendingEpoch: UUID?
    private var pendingConnectionConfirmation: (ExternalConnectionRecoveryConfirmation, UUID)?
    private var confirmedRecoveryEpoch: UUID?
    private var automaticReapplicationAllowed = false
    private var unknownChangePending = false
    private var operationEpoch = UUID()
    private var handler: (@Sendable (PrimarySessionStatus) -> Void)?
    private var verifier: ExternalDisplayVerification?
    private let scheduler: PrimaryReapplicationScheduler
    private var powerObserver: InternalSystemPowerObserver?
    private var displayRegistered = false
    private var started = false
    private var retired = false
    private var holding = false
    private var automaticInput: ExternalAutomaticInputSession?
    private var sendInputOnStart = false
    private var inputResult: (@Sendable (ExternalDisplayInputResult) -> Void)?

    init(directory: URL, recoveryStore: RecoveryStore? = nil,
         verificationFactory: @escaping Factory = { directory, store, check, native in
             try ExternalDisplayVerification(directory: directory, recoveryStore: store,
                 writeOrigins: { origins, validate in
                     try configureOrigins(origins, option: .forSession, nativeCall: native, validateBeforeCommit: validate)
                 }, nativeCall: native, checkAccess: check)
         }) throws {
        self.directory = directory
        store = try recoveryStore ?? RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        factory = verificationFactory
        scheduler = PrimaryReapplicationScheduler(ownerQueue: queue)
    }

    deinit { stopEvents() }

    func startApplication(registerEvents: Bool, recoveryOnly: Bool,
                          onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
        guard let epoch = request("start") else { return }
        if registerEvents {
            do { try startEvents() }
            catch { finish(epoch); onStatus(.recoveryIncomplete); return }
        } else { gate.didRegister() }
        queue.async {
            guard !self.started else { self.finish(epoch); return }
            self.started = true
            self.handler = onStatus
            self.operationEpoch = epoch
            self.publish(.applying)
            do {
                let verifier = try self.factory(self.directory, self.store, { try self.checkAccess() }, {
                    try self.checkAccess()
                    return try self.gate.perform($0)
                })
                self.verifier = verifier
                if try verifier.hasRecord() {
                    self.holding = true
                    let status = try verifier.reconcile(allowReapplication: false)
                    self.holding = status == .applied
                    self.publishIfCurrent(status, epoch: epoch)
                } else if recoveryOnly {
                    self.publishIfCurrent(.manualConfiguration, epoch: epoch)
                } else {
                    try self.explicitDisable(verifier, sendInput: self.sendInputOnStart)
                    self.holding = true
                    self.publishIfCurrent(.applied, epoch: epoch)
                }
            } catch { self.publishFailure(error, epoch: epoch) }
            self.finish(epoch)
        }
    }

    func retryApplication() {
        guard let epoch = request("apply") else { return }
        queue.async {
            self.operationEpoch = epoch
            defer { self.finish(epoch) }
            guard !self.retired, let verifier = self.verifier else { return }
            self.publish(.applying)
            do {
                try self.checkAccess()
                try self.explicitDisable(verifier, sendInput: true)
                self.holding = true
                self.publishIfCurrent(.applied, epoch: epoch)
            } catch { self.publishFailure(error, epoch: epoch) }
        }
    }

    func recoverApplication() {
        guard let epoch = request("restore") else { return }
        recover(epoch: epoch, confirmation: nil)
    }

    func prepareConnectionRecovery(completion: @escaping @Sendable (Result<ExternalConnectionRecoveryConfirmation?, Error>) -> Void) {
        guard let epoch = request("prepare-connection") else { completion(.failure(RecoveryError.invalidTransition)); return }
        queue.async {
            self.operationEpoch = epoch
            var result: Result<ExternalConnectionRecoveryConfirmation?, Error> = .failure(RecoveryError.invalidTransition)
            if !self.retired, let verifier = self.verifier {
                do {
                    let confirmation = try verifier.prepareConnectionRecovery()
                    self.lock.withLock {
                        if self.requestedEpoch == epoch {
                            if let confirmation { self.pendingConnectionConfirmation = (confirmation, epoch) }
                            result = .success(confirmation)
                        } else { confirmation?.cancel() }
                    }
                } catch {
                    result = .failure(error)
                    self.publishFailure(error, epoch: epoch)
                }
            }
            self.finish(epoch)
            completion(result)
        }
    }

    func recoverAfterConfirmingConnection(_ confirmation: ExternalConnectionRecoveryConfirmation) {
        guard let epoch = request("restore", confirmation: confirmation) else {
            confirmation.cancel()
            if let current = lock.withLock({ pendingAction == nil ? requestedEpoch : nil }) {
                queue.async { if !self.retired { self.publishIfCurrent(.recoveryIncomplete, epoch: current) } }
            }
            return
        }
        recover(epoch: epoch, confirmation: confirmation)
    }

    private func recover(epoch: UUID, confirmation: ExternalConnectionRecoveryConfirmation?) {
        queue.async {
            self.operationEpoch = epoch
            self.scheduler.cancel()
            self.holding = false
            self.setAutomaticReapplicationAllowed(false)
            defer { self.finish(epoch) }
            guard !self.retired, let verifier = self.verifier else { return }
            self.publish(.applying)
            do {
                try verifier.restore(confirmation: confirmation, connectionEnabled: {
                    self.lock.withLock {
                        if self.confirmedRecoveryEpoch == epoch { self.confirmedRecoveryEpoch = nil }
                    }
                })
                self.publishIfCurrent(.manualConfiguration, epoch: epoch)
            } catch { self.publishFailure(error, epoch: epoch) }
        }
    }

    func confirmCurrentConfiguration() {
        guard let epoch = request("confirm") else { return }
        queue.async {
            self.operationEpoch = epoch
            defer { self.finish(epoch) }
            guard !self.retired, let verifier = self.verifier else { return }
            self.scheduler.cancel()
            do {
                try verifier.confirmUserLayout()
                self.setAutomaticReapplicationAllowed(false)
                self.holding = false
                self.publishIfCurrent(.manualConfiguration, epoch: epoch)
            } catch { self.publishIfCurrent(.confirmationFailed, epoch: epoch) }
        }
    }

    func quitApplication(completion: @escaping @Sendable (Bool) -> Void) {
        guard let epoch = request("quit") else { completion(false); return }
        queue.async {
            self.operationEpoch = epoch
            self.scheduler.cancel()
            self.holding = false
            defer { self.finish(epoch) }
            do {
                if let verifier = self.verifier, try verifier.hasRecord() {
                    try verifier.restore()
                } else if try self.store.load() != nil {
                    throw RecoveryError.unfinishedTransaction
                }
                try self.checkAccess()
                self.retired = true
                self.stopEvents()
                completion(true)
            } catch { self.publish(.quitFailed); completion(false) }
        }
    }

    func configureAutomaticInput(_ session: ExternalAutomaticInputSession?, sendOnStart: Bool = false,
                                 onResult: @escaping @Sendable (ExternalDisplayInputResult) -> Void = { _ in }) {
        queue.async {
            self.automaticInput = session
            self.sendInputOnStart = sendOnStart
            self.inputResult = onResult
        }
    }

    private func explicitDisable(_ verifier: ExternalDisplayVerification, sendInput: Bool) throws {
        var session = sendInput ? automaticInput : nil
        var prepared = false
        try verifier.disable { target in prepared = session?.prepare(for: target) == true }
        guard sendInput, automaticInput != nil else { return }
        guard prepared, let target = try verifier.targetIdentity() else { inputResult?(.unavailable); return }
        do {
            try checkAccess()
            guard try verifier.reconcile(allowReapplication: false) == .applied else {
                inputResult?(.unconfirmed)
                return
            }
            guard try verifier.hasCompleteIdentityForInput() else { inputResult?(.unconfirmed); return }
            try checkAccess()
            inputResult?(session?.sendOnce(to: target) ?? .unavailable)
        } catch { inputResult?(.unconfirmed) }
    }

    func setAutomaticReapplicationAllowed(_ allowed: Bool) {
        lock.withLock { automaticReapplicationAllowed = allowed }
    }

    // 来源未知的配置变化只核对，不凭 enabled/remove 回调推断用户意图。
    func displayChanged() {
        if let cancelled = invalidateConnectionConfirmation() {
            queue.async { if !self.retired { self.publishIfCurrent(.recoveryIncomplete, epoch: cancelled) } }
        }
        scheduleReadback(allowReapplication: false)
    }

    @discardableResult
    private func invalidateConnectionConfirmation() -> UUID? {
        lock.withLock {
            pendingConnectionConfirmation?.0.cancel()
            pendingConnectionConfirmation = nil
            let revoked = confirmedRecoveryEpoch == requestedEpoch || pendingAction == "prepare-connection"
            if revoked { requestedEpoch = UUID() }
            confirmedRecoveryEpoch = nil
            return revoked ? requestedEpoch : nil
        }
    }

    func willSleep() {
        _ = gate.willSleep()
        scheduler.invalidate()
        invalidateConnectionConfirmation()
        lock.withLock { requestedEpoch = UUID() }
        queue.async { if !self.retired { self.publish(.recoveryIncomplete) } }
    }

    func didPrepareForSleep(_ acknowledged: Bool) { gate.didAcknowledgeSleep(acknowledged) }

    func didWake() {
        _ = gate.didWake()
        invalidateConnectionConfirmation()
        scheduleReadback(allowReapplication: true)
    }

    private func scheduleReadback(allowReapplication: Bool) {
        queue.async {
            guard !self.retired, self.holding else { return }
            if !allowReapplication { self.unknownChangePending = true }
            self.scheduler.schedule { isCurrent in
                guard isCurrent(), self.holding, self.gate.isReady, self.lock.withLock({ self.pendingAction == nil }),
                      let verifier = self.verifier else { return }
                let epoch = self.lock.withLock { self.requestedEpoch }
                self.operationEpoch = epoch
                do {
                    let allow = allowReapplication && !self.unknownChangePending
                        && self.lock.withLock { self.automaticReapplicationAllowed }
                    let status = try verifier.reconcile(allowReapplication: allow)
                    self.unknownChangePending = false
                    self.holding = status == .applied
                    self.publishIfCurrent(status, epoch: epoch)
                } catch { self.publishFailure(error, epoch: epoch) }
            }
        }
    }

    private func request(_ action: String, confirmation: ExternalConnectionRecoveryConfirmation? = nil) -> UUID? {
        lock.withLock {
            if pendingAction == action || pendingAction == "quit" { return nil }
            if let confirmation {
                guard let pending = pendingConnectionConfirmation, pending.0 === confirmation,
                      pending.1 == requestedEpoch else { return nil }
            } else { pendingConnectionConfirmation?.0.cancel() }
            pendingConnectionConfirmation = nil
            let epoch = UUID()
            requestedEpoch = epoch
            confirmedRecoveryEpoch = confirmation == nil ? nil : epoch
            pendingAction = action
            pendingEpoch = epoch
            return epoch
        }
    }

    private func finish(_ epoch: UUID) {
        lock.withLock {
            if pendingEpoch == epoch { pendingAction = nil; pendingEpoch = nil }
            if confirmedRecoveryEpoch == epoch { confirmedRecoveryEpoch = nil }
        }
    }

    private func checkAccess() throws {
        try gate.check()
        guard lock.withLock({ requestedEpoch == operationEpoch }) else { throw RecoveryError.invalidTransition }
    }

    private func publishFailure(_ error: Error, epoch: UUID) {
        if case RecoveryError.unresolvedSource = error { publishIfCurrent(.unconfirmed, epoch: epoch) }
        else { publishIfCurrent(.recoveryIncomplete, epoch: epoch) }
    }

    private func publishIfCurrent(_ value: PrimarySessionStatus, epoch: UUID) {
        if lock.withLock({ requestedEpoch == epoch }) { publish(value) }
    }

    private func publish(_ value: PrimarySessionStatus) { handler?(value) }

    private func startEvents() throws {
        let observer = InternalSystemPowerObserver(
            prepareForSleep: { [weak self] in
                guard let self else { return false }
                self.willSleep()
                return true
            },
            didPrepareForSleep: { [weak self] accepted, acknowledged in
                if accepted { self?.gate.didAcknowledgeSleep(acknowledged) }
            },
            didWake: { [weak self] in self?.didWake() }, onFailure: { [weak self] in self?.gate.invalidate() }
        )
        try observer.start()
        powerObserver = observer
        gate.didRegister()
        guard CGDisplayRegisterReconfigurationCallback(externalApplicationDisplayCallback,
            Unmanaged.passUnretained(self).toOpaque()) == .success else {
            stopEvents()
            throw RecoveryError.invalidTransition
        }
        displayRegistered = true
    }

    private func stopEvents() {
        if displayRegistered {
            CGDisplayRemoveReconfigurationCallback(externalApplicationDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
            displayRegistered = false
        }
        powerObserver?.stop()
        powerObserver = nil
        gate.invalidate()
    }
}

extension ExternalApplicationController: PrimaryApplicationControlling, ExternalConnectionRecoveryControlling {}

private let externalApplicationDisplayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    Unmanaged<ExternalApplicationController>.fromOpaque(context).takeUnretainedValue().displayChanged()
}
