import Darwin
import ExtilumeCore
import Foundation

@MainActor
final class DisplayModeCoordinator: PrimaryApplicationControlling, DisplayModeSelecting, ExternalConnectionRecoveryControlling {
    typealias ControllerFactory = @MainActor (DisplayApplicationMode, URL, RecoveryStore?) throws -> any PrimaryApplicationControlling

    private let directory: URL
    private let lease: RecoveryStore
    private let preferences: any DisplayModePreferenceStoring
    private let factory: ControllerFactory
    private let inputSettings: ExternalDisplayInputSettings
    let availableModes: [DisplayApplicationMode]
    private var controller: (any PrimaryApplicationControlling)?
    private var activeMode: DisplayApplicationMode?
    private var generation = UUID()
    private var status: PrimarySessionStatus = .waiting
    private var ownerStatus: PrimarySessionStatus = .waiting
    private var onStatus: (@Sendable (PrimarySessionStatus) -> Void)?
    private var registerEvents = true
    private var transitionPending = false
    private var quitPending = false
    private var ownerRetiring = false
    private var handoffCleanupPending = false
    private var actionPending = false
    private var internalFailureLatched = false
    private var failureLatchPersisted = true
    private var pendingStartupRecovery: DisplayApplicationMode?
    private var conflictingResponsibilities = false
    private var connectionRecoveryConfirmation: (ExternalConnectionRecoveryConfirmation, UUID)?

    private(set) var selectedMode: DisplayApplicationMode?
    private(set) var requiresExplicitActivation = false
    var modeDidChange: (@MainActor () -> Void)?

    init(directory: URL, preferences: any DisplayModePreferenceStoring = DisplayModePreferences(),
         availableModes: [DisplayApplicationMode] = [.externalPrimary, .externalOnly],
         inputSettings: ExternalDisplayInputSettings = ExternalDisplayInputSettings(),
         factory: @escaping ControllerFactory = { mode, directory, store in
             switch mode {
             case .externalPrimary: try PrimaryController(directory: directory, recoveryStore: store)
             case .externalOnly: try InternalApplicationController(directory: directory)
             case .internalOnly: try ExternalApplicationController(directory: directory, recoveryStore: store)
             }
         }) throws {
        self.directory = directory
        self.preferences = preferences
        self.availableModes = availableModes
        self.inputSettings = inputSettings
        self.factory = factory
        selectedMode = preferences.selectedMode
        internalFailureLatched = preferences.internalControlLocked
        requiresExplicitActivation = selectedMode == .externalOnly
            || (selectedMode == .internalOnly && !preferences.externalHandoffRequested)
        lease = try RecoveryStore(directory: directory)
        try lease.acquireExclusiveOwnership()
        let previous = try lease.load()
        if previous?.internalDisplay != nil { conflictingResponsibilities = true }
        if let previous {
            pendingStartupRecovery = previous.externalDisplay == nil ? .externalPrimary : .internalOnly
            if previous.externalDisplay != nil {
                selectedMode = .internalOnly
                requiresExplicitActivation = false
            }
        }
        let internalDirectory = directory.appendingPathComponent("internal-session", isDirectory: true)
        if FileManager.default.fileExists(atPath: internalDirectory.path) {
            let internalStore = try RecoveryStore(directory: internalDirectory)
            var pending = false
            do { try internalStore.acquireExclusiveOwnership() }
            catch RecoveryStoreError.ownershipUnavailable { pending = true }
            if try internalStore.load() != nil { pending = true }
            if pending {
                if previous != nil && previous?.canClear != true { conflictingResponsibilities = true }
                pendingStartupRecovery = .externalOnly
                internalFailureLatched = true
                try preferences.lockInternalControl()
            }
        }
    }

    func startApplication(registerEvents: Bool, recoveryOnly: Bool,
                          onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
        guard self.onStatus == nil else { return }
        self.onStatus = onStatus
        self.registerEvents = registerEvents
        if conflictingResponsibilities { publish(.recoveryIncomplete); return }
        if let pendingStartupRecovery {
            start(pendingStartupRecovery, recoveryOnly: true)
        } else if !recoveryOnly, selectedMode == .externalPrimary {
            start(.externalPrimary, recoveryOnly: false)
        } else if !recoveryOnly, selectedMode == .internalOnly, preferences.externalHandoffRequested,
                  availableModes.contains(.internalOnly) {
            start(.internalOnly, recoveryOnly: false)
        } else {
            publish(.waiting)
        }
    }

    func selectMode(_ mode: DisplayApplicationMode) {
        guard availableModes.contains(mode) else { return }
        guard !transitionPending, !quitPending, !actionPending, !status.needsRecovery,
              status != .applying, status != .restoringAndQuitting,
              status != .manualConfigurationForQuit else { return }
        if selectedMode == mode, activeMode == mode, ownerStatus == .applied, !ownerRetiring { return }
        do {
            try preferences.select(mode)
            if mode == .internalOnly { try preferences.setExternalHandoffRequested(true) }
        }
        catch { publish(.unsupported("无法保存模式选择")); return }
        selectedMode = mode
        if mode == .internalOnly {
            (controller as? ExternalApplicationController)?.setAutomaticReapplicationAllowed(true)
        }
        requiresExplicitActivation = false
        modeDidChange?()
        if mode == .externalOnly && internalFailureLatched {
            publish(.unsupported("保护曾失效，仅外屏需修复并重新验收"))
            return
        }
        if controller == nil { start(mode, recoveryOnly: false, explicitSelection: true); return }
        if activeMode == mode, pendingStartupRecovery == nil, !ownerRetiring {
            if status.canRetryApplication || ((mode == .externalOnly || mode == .internalOnly)
                && (status == .waiting || isUnsupported(status))) {
                publish(.applying)
                configureInput(for: controller, sendOnStart: false)
                controller?.retryApplication()
            }
            else { publish(ownerStatus) }
            return
        }
        finishHandoff(to: mode)
    }

    func retryApplication() {
        guard !transitionPending, !quitPending, !actionPending, status.canRetryApplication,
              let selectedMode else { return }
        selectMode(selectedMode)
    }

    func restoreForConfiguration() {
        guard !transitionPending, !quitPending, !actionPending,
              let activeMode, (activeMode == .externalOnly || activeMode == .internalOnly),
              status == .applied, let controller else { return }
        if activeMode == .internalOnly, !clearExternalHandoffRequest() { return }
        actionPending = true
        publish(.applying)
        controller.recoverApplication()
    }

    func recoverApplication() {
        guard !transitionPending, !quitPending, !actionPending, status.canRetryRecovery,
              !conflictingResponsibilities else { return }
        if activeMode == .internalOnly, !clearExternalHandoffRequest() { return }
        if handoffCleanupPending { finishHandoff(to: nil); return }
        if let controller { actionPending = true; controller.recoverApplication() }
        else if let pendingStartupRecovery { start(pendingStartupRecovery, recoveryOnly: true) }
    }

    func confirmCurrentConfiguration() {
        guard !transitionPending, !quitPending, !actionPending, let controller,
              !(activeMode == .externalOnly && status == .quitFailed),
              status.canConfirmConfiguration || (activeMode == .externalOnly && status == .manualConfiguration) else { return }
        actionPending = true
        controller.confirmCurrentConfiguration()
    }

    func prepareConnectionRecovery(completion: @escaping @Sendable (Result<ExternalConnectionRecoveryConfirmation?, Error>) -> Void) {
        connectionRecoveryConfirmation?.0.cancel()
        connectionRecoveryConfirmation = nil
        guard activeMode == .internalOnly, !transitionPending, !quitPending, !actionPending,
              !conflictingResponsibilities, status == .applied || status.canRetryRecovery,
              let recovery = controller as? any ExternalConnectionRecoveryControlling else {
            completion(.failure(RecoveryError.invalidTransition))
            return
        }
        let owner = generation
        recovery.prepareConnectionRecovery { [weak self] result in
            Self.onMainRunLoop { [weak self] in
                guard let self, self.generation == owner, self.activeMode == .internalOnly,
                      !self.transitionPending, !self.quitPending, !self.actionPending else {
                    if case .success(let confirmation) = result { confirmation?.cancel() }
                    completion(.failure(RecoveryError.invalidTransition))
                    return
                }
                if case .success(let confirmation?) = result { self.connectionRecoveryConfirmation = (confirmation, owner) }
                completion(result)
            }
        }
    }

    func recoverAfterConfirmingConnection(_ confirmation: ExternalConnectionRecoveryConfirmation) {
        guard let prepared = connectionRecoveryConfirmation, prepared.0 === confirmation, prepared.1 == generation,
              activeMode == .internalOnly, !transitionPending, !quitPending, !actionPending,
              !conflictingResponsibilities, status == .applied || status.canRetryRecovery,
              let recovery = controller as? any ExternalConnectionRecoveryControlling else {
            confirmation.cancel()
            return
        }
        connectionRecoveryConfirmation = nil
        guard clearExternalHandoffRequest() else { confirmation.cancel(); return }
        actionPending = true
        publish(.applying)
        recovery.recoverAfterConfirmingConnection(confirmation)
    }

    func quitApplication(completion: @escaping @Sendable (Bool) -> Void) {
        guard !transitionPending, !quitPending, !conflictingResponsibilities else { completion(false); return }
        if activeMode == .internalOnly, !clearExternalHandoffRequest() { completion(false); return }
        guard failureLatchPersisted || latchFailure() else { completion(false); return }
        guard !handoffCleanupPending else { completion(false); return }
        guard let controller else {
            completion(pendingStartupRecovery == nil)
            return
        }
        quitPending = true
        ownerRetiring = true
        let oldGeneration = generation
        controller.quitApplication { [weak self] restored in
            Self.onMainRunLoop { [weak self] in
                guard let self, self.generation == oldGeneration else { completion(false); return }
                self.quitPending = false
                if !restored { self.latchFailure(); self.publish(.quitFailed) }
                completion(restored)
            }
        }
    }

    private func start(_ mode: DisplayApplicationMode, recoveryOnly: Bool, explicitSelection: Bool = false) {
        do {
            let target: URL
            let sharedStore: RecoveryStore?
            if mode == .externalPrimary {
                target = directory
                sharedStore = lease
            } else if mode == .internalOnly {
                target = directory
                sharedStore = lease
            } else {
                target = directory.appendingPathComponent("internal-session", isDirectory: true)
                if mkdir(target.path, mode_t(0o700)) != 0 && errno != EEXIST { throw RecoveryStoreError.ioFailure }
                _ = try RecoveryStore(directory: target)
                sharedStore = nil
            }
            let next = try factory(mode, target, sharedStore)
            let run = UUID()
            generation = run
            controller = next
            activeMode = mode
            ownerRetiring = false
            if let internalController = next as? InternalApplicationController {
                internalController.persistFailureForExit = { [weak self] in
                    guard let self, self.generation == run, self.activeMode == .externalOnly else { return false }
                    return self.latchFailure()
                }
            }
            if let externalController = next as? ExternalApplicationController {
                externalController.setAutomaticReapplicationAllowed(
                    availableModes.contains(.internalOnly) && preferences.externalHandoffRequested
                )
            }
            configureInput(for: next, sendOnStart: explicitSelection && !recoveryOnly)
            publish(.applying)
            next.startApplication(registerEvents: registerEvents && !(mode == .externalPrimary && recoveryOnly),
                                  recoveryOnly: recoveryOnly) { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == run, !self.transitionPending else { return }
                    self.actionPending = false
                    self.ownerStatus = value
                    if mode == .internalOnly, value == .manualConfiguration,
                       !self.clearExternalHandoffRequest() { return }
                    if mode == .externalOnly && [.recoveryIncomplete, .quitFailed, .quitWaitingForDisplays,
                                                .applicationFailedRestored].contains(value), !self.latchFailure() { return }
                    self.publish(value)
                }
            }
        } catch {
            publish(pendingStartupRecovery == nil ? .unsupported("无法安全启动模式，请重新选择") : .recoveryIncomplete)
        }
    }

    private func finishHandoff(to mode: DisplayApplicationMode?) {
        if activeMode == .internalOnly, !clearExternalHandoffRequest() { return }
        transitionPending = true
        ownerRetiring = true
        publish(.applying)
        let oldGeneration = generation
        controller?.quitApplication { [weak self] restored in
            Self.onMainRunLoop { [weak self] in
                guard let self, self.generation == oldGeneration else { return }
                self.transitionPending = false
                guard restored else { self.latchFailure(); self.publish(.quitFailed); return }
                do { try self.lease.clear() }
                catch {
                    self.handoffCleanupPending = true
                    self.publish(.recoveryIncomplete)
                    return
                }
                self.generation = UUID()
                self.controller = nil
                self.activeMode = nil
                self.pendingStartupRecovery = nil
                self.handoffCleanupPending = false
                self.ownerRetiring = false
                if mode == .externalOnly && self.internalFailureLatched {
                    self.publish(.unsupported("保护曾失效，仅外屏需修复并重新验收"))
                } else if let mode { self.start(mode, recoveryOnly: false, explicitSelection: true) }
                else { self.publish(.applicationFailedRestored) }
            }
        }
    }

    private func configureInput(for owner: (any PrimaryApplicationControlling)?, sendOnStart: Bool) {
        guard let external = owner as? ExternalApplicationController else { return }
        external.configureAutomaticInput(inputSettings.automaticSession, sendOnStart: sendOnStart) { [weak self] result in
            DispatchQueue.main.async { [weak self] in self?.inputSettings.recordResult(result) }
        }
    }

    @discardableResult
    private func latchFailure() -> Bool {
        guard activeMode == .externalOnly else { return true }
        internalFailureLatched = true
        do { try preferences.lockInternalControl(); failureLatchPersisted = true; return true }
        catch { failureLatchPersisted = false; publish(.recoveryIncomplete); return false }
    }

    private func isUnsupported(_ status: PrimarySessionStatus) -> Bool {
        if case .unsupported = status { return true }
        return false
    }

    private func clearExternalHandoffRequest() -> Bool {
        guard preferences.externalHandoffRequested else { return true }
        do { try preferences.setExternalHandoffRequested(false); return true }
        catch { publish(.recoveryIncomplete); return false }
    }

    private func publish(_ status: PrimarySessionStatus) {
        let visible: PrimarySessionStatus
        if status == .applied, let activeMode, activeMode != selectedMode {
            visible = .unsupported("所选模式尚未生效，当前仍为\(activeMode.title)")
        } else if status == .manualConfiguration, let activeMode, activeMode != selectedMode {
            visible = .unsupported("所选模式尚未生效，\(activeMode.title)会话已暂停")
        } else { visible = status }
        self.status = visible
        onStatus?(visible)
    }

    private nonisolated static func onMainRunLoop(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) { MainActor.assumeIsolated { action() } }
    }
}

extension DisplayModeCoordinator: ExternalDisplayInputSettingsSelecting {
    var inputOptions: [UInt16] { inputSettings.inputOptions }
    var selectedPCInput: UInt16? { inputSettings.selectedPCInput }
    var automaticInputEnabled: Bool { inputSettings.automaticInputEnabled }
    var inputUnavailableReason: String? { inputSettings.inputUnavailableReason }
    var inputResultText: String? { inputSettings.inputResultText }
    var inputSettingsDidChange: (@MainActor () -> Void)? {
        get { inputSettings.inputSettingsDidChange }
        set { inputSettings.inputSettingsDidChange = newValue }
    }
    func selectPCInput(_ input: UInt16) { inputSettings.selectPCInput(input) }
    func setAutomaticInput(_ enabled: Bool) { inputSettings.setAutomaticInput(enabled) }
}
