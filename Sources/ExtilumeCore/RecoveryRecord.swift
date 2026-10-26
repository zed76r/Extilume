import Foundation

public struct DisplayOrigin: Codable, Equatable, Sendable {
    public let x: Int32
    public let y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct DisplayLayout: Codable, Equatable, Sendable {
    public let main: UUID
    public let origins: [UUID: DisplayOrigin]

    public init(main: UUID, origins: [UUID: DisplayOrigin]) throws {
        guard origins[main] == DisplayOrigin(x: 0, y: 0) else { throw RecoveryError.invalidRecord }
        self.main = main
        self.origins = origins
    }
}

public enum RecoveryError: Error {
    case invalidRecord
    case unresolvedSource
    case unfinishedTransaction
    case identityConflict
    case invalidTransition
}

public enum ConfigurationSource: Equatable {
    case confirmedUser
    case ownCallback
    case reconnect
    case unknown
}

public enum TransactionPhase: String, Codable, Sendable {
    case prepared
    case applying
    case owned
    case restoring
    case restored
}

public struct InternalDisplayHardwareIdentity: Codable, Equatable, Sendable {
    public let bootSession: UUID
    public let registryEntryID: UInt64

    public init(bootSession: UUID, registryEntryID: UInt64) {
        self.bootSession = bootSession
        self.registryEntryID = registryEntryID
    }

    public func validate() throws {
        guard registryEntryID > 0,
              bootSession.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw RecoveryError.invalidRecord
        }
    }
}

public struct InternalDisplayResponsibility: Codable, Equatable, Sendable {
    public let identity: UUID
    public fileprivate(set) var baseline: Bool
    public private(set) var applied: Bool
    public fileprivate(set) var pending: Bool
    public let hardwareIdentity: InternalDisplayHardwareIdentity?
    public let numericIDHint: UInt32?

    public init(
        identity: UUID,
        baseline: Bool,
        applied: Bool,
        hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
        numericIDHint: UInt32? = nil
    ) {
        self.identity = identity
        self.baseline = baseline
        self.applied = applied
        self.pending = baseline != applied
        self.hardwareIdentity = hardwareIdentity
        self.numericIDHint = numericIDHint
    }
}

public struct ExternalDisplayResponsibility: Codable, Equatable, Sendable {
    public let identity: ExternalDisplayIdentity
    public let numericIDHint: UInt32
    public internal(set) var baseline: Bool
    public internal(set) var applied: Bool
    public internal(set) var pending: Bool

    public init(identity: ExternalDisplayIdentity, numericIDHint: UInt32, baseline: Bool, applied: Bool) {
        self.identity = identity
        self.numericIDHint = numericIDHint
        self.baseline = baseline
        self.applied = applied
        self.pending = baseline != applied
    }
}

public struct ConnectedDisplay: Equatable {
    public let identity: UUID
    public let numericID: UInt32

    public init(identity: UUID, numericID: UInt32) {
        self.identity = identity
        self.numericID = numericID
    }
}

public struct LayoutRestorePlan: Equatable {
    public let origins: [UInt32: DisplayOrigin]
    public let missing: Set<UUID>
}

public struct RecoveryRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let session: UUID
    public private(set) var generation: UInt64
    public private(set) var phase: TransactionPhase
    public private(set) var baseline: DisplayLayout
    public private(set) var applied: DisplayLayout
    public private(set) var preDisableLayout: DisplayLayout?
    public private(set) var layoutPending: Bool
    public private(set) var internalDisplay: InternalDisplayResponsibility?
    public private(set) var externalDisplay: ExternalDisplayResponsibility?
    public private(set) var sourceUnresolved: Bool
    public private(set) var independentGuardVerified: Bool?

    public var requiresRecovery: Bool { layoutPending || internalDisplay?.pending == true || externalDisplay?.pending == true }
    public var canClear: Bool { phase == .restored && !requiresRecovery && !sourceUnresolved }

    public init(
        session: UUID = UUID(),
        baseline: DisplayLayout,
        target: DisplayLayout,
        internalDisplay: InternalDisplayResponsibility? = nil,
        externalDisplay: ExternalDisplayResponsibility? = nil
    ) throws {
        self.version = externalDisplay != nil ? 4 : (internalDisplay?.hardwareIdentity == nil ? 2 : 3)
        self.session = session
        self.generation = 1
        self.phase = .prepared
        self.baseline = baseline
        self.applied = target
        self.preDisableLayout = nil
        self.layoutPending = baseline != target
        self.internalDisplay = internalDisplay
        self.externalDisplay = externalDisplay
        self.sourceUnresolved = false
        self.independentGuardVerified = nil
        try validate()
    }

    public func validate() throws {
        let baselineKeys = Set(baseline.origins.keys)
        let appliedKeys = Set(applied.origins.keys)
        let fullLayout = baselineKeys == appliedKeys
        let hardwareIdentityValid: Bool
        switch version {
        case 1, 2:
            hardwareIdentityValid = internalDisplay?.hardwareIdentity == nil
        case 3:
            if let hardwareIdentity = internalDisplay?.hardwareIdentity {
                do {
                    try hardwareIdentity.validate()
                    hardwareIdentityValid = true
                } catch {
                    hardwareIdentityValid = false
                }
            } else {
                hardwareIdentityValid = false
            }
        case 4:
            if let hardwareIdentity = internalDisplay?.hardwareIdentity {
                do {
                    try hardwareIdentity.validate()
                    hardwareIdentityValid = true
                } catch {
                    hardwareIdentityValid = false
                }
            } else {
                hardwareIdentityValid = true
            }
        default:
            hardwareIdentityValid = false
        }
        let validSubset: Bool = {
            guard version == 2 || version == 3,
                  phase == .owned || phase == .restoring || phase == .restored,
                  let responsibility = internalDisplay,
                  responsibility.baseline, !responsibility.applied,
                  let preDisableLayout,
                  Set(preDisableLayout.origins.keys) == baselineKeys,
                  preDisableLayout.origins[preDisableLayout.main] == DisplayOrigin(x: 0, y: 0),
                  preDisableLayout.main == applied.main,
                  preDisableLayout.main != responsibility.identity,
                  preDisableLayout.origins[preDisableLayout.main] == applied.origins[applied.main] else { return false }
            let expectedKeys = baselineKeys.subtracting([responsibility.identity])
            return appliedKeys == expectedKeys
                && applied.origins.allSatisfy({ preDisableLayout.origins[$0.key] == $0.value })
                && Set(baselineKeys).subtracting(appliedKeys) == [responsibility.identity]
                && appliedKeys.isSubset(of: baselineKeys)
        }()
        let validExternalSubset: Bool = {
            guard version == 4,
                  phase == .owned || phase == .restoring || phase == .restored,
                  let responsibility = externalDisplay,
                  responsibility.baseline, !responsibility.applied,
                  baselineKeys.count == 2,
                  let preDisableLayout,
                  Set(preDisableLayout.origins.keys) == baselineKeys,
                  preDisableLayout.origins[preDisableLayout.main] == DisplayOrigin(x: 0, y: 0),
                  preDisableLayout.main == applied.main,
                  preDisableLayout.main != responsibility.identity.uuid,
                  preDisableLayout.origins[preDisableLayout.main] == applied.origins[applied.main] else { return false }
            let expectedKeys = baselineKeys.subtracting([responsibility.identity.uuid])
            return appliedKeys == expectedKeys
                && appliedKeys.count == 1
                && applied.origins.allSatisfy({ preDisableLayout.origins[$0.key] == $0.value })
                && Set(baselineKeys).subtracting(appliedKeys) == [responsibility.identity.uuid]
                && appliedKeys.isSubset(of: baselineKeys)
        }()
        let layoutFormatValid = version == 1
            ? preDisableLayout == nil && fullLayout
            : preDisableLayout == nil ? fullLayout : (validSubset || validExternalSubset)
        let externalIdentityValid: Bool = {
            switch version {
            case 1, 2, 3:
                return externalDisplay == nil
            case 4:
                guard let responsibility = externalDisplay,
                      responsibility.numericIDHint > 0,
                      baseline.origins[responsibility.identity.uuid] != nil,
                      internalDisplay?.identity != responsibility.identity.uuid else { return false }
                do {
                    try responsibility.identity.validate()
                    return true
                } catch {
                    return false
                }
            default:
                return false
            }
        }()
        let mutuallyExclusiveDisableResponsibilities = !(
            internalDisplay.map { $0.pending && !$0.applied } == true
                && externalDisplay.map { $0.pending && !$0.applied } == true
        )
        let independentGuardVerificationValid = independentGuardVerified.map {
            $0 && canClear && internalDisplay != nil
        } ?? true
        guard (version == 1 || version == 2 || version == 3 || version == 4), hardwareIdentityValid,
              externalIdentityValid, mutuallyExclusiveDisableResponsibilities, generation > 0,
              internalDisplay?.numericIDHint != 0,
              baseline.origins[baseline.main] == DisplayOrigin(x: 0, y: 0),
              applied.origins[applied.main] == DisplayOrigin(x: 0, y: 0),
              layoutFormatValid,
              internalDisplay.map({ baseline.origins[$0.identity] != nil }) ?? true,
              independentGuardVerificationValid,
              phase != .restored || (!requiresRecovery && !sourceUnresolved),
              (phase != .prepared && phase != .applying) || layoutPending == (baseline != applied),
              (phase != .prepared && phase != .applying) || internalDisplay.map({ $0.pending == ($0.baseline != $0.applied) }) ?? true,
              (phase != .prepared && phase != .applying) || externalDisplay.map({ $0.pending == ($0.baseline != $0.applied) }) ?? true else { throw RecoveryError.invalidRecord }
    }

    public mutating func markApplying() throws {
        guard phase == .prepared, !sourceUnresolved else { throw RecoveryError.invalidTransition }
        phase = .applying
    }

    // 仅用于尚未调用操作的预检失败；旧 applied 即使无 pending 也关系到退出补偿。
    mutating func cancelBeforeApplication(previous: RecoveryRecord?) throws {
        guard phase == .applying, !sourceUnresolved else { throw RecoveryError.invalidTransition }
        if let previous, previous.phase == .owned {
            guard previous.session == session, previous.baseline == baseline,
                  previous.generation < generation else { throw RecoveryError.invalidTransition }
            let cancelledGeneration = generation
            self = previous
            generation = cancelledGeneration
        } else {
            guard previous == nil || previous?.canClear == true else { throw RecoveryError.invalidTransition }
            applied = baseline
            preDisableLayout = nil
            layoutPending = false
            if let responsibility = internalDisplay {
                internalDisplay = InternalDisplayResponsibility(
                    identity: responsibility.identity, baseline: responsibility.baseline,
                    applied: responsibility.baseline,
                    hardwareIdentity: responsibility.hardwareIdentity, numericIDHint: responsibility.numericIDHint
                )
            }
            if var responsibility = externalDisplay {
                responsibility.applied = responsibility.baseline
                responsibility.pending = false
                externalDisplay = responsibility
            }
        }
        phase = .owned
        try validate()
    }

    public mutating func confirmApplied(
        _ actual: DisplayLayout,
        internalEnabled: Bool? = nil,
        externalEnabled: Bool? = nil
    ) throws {
        guard phase == .applying || phase == .prepared else { throw RecoveryError.invalidTransition }
        if let responsibility = externalDisplay,
           responsibility.baseline, !responsibility.applied, responsibility.pending {
            guard phase == .applying, version == 4, !sourceUnresolved,
                  internalEnabled == true,
                  externalEnabled == false,
                  actual.main == applied.main,
                  actual.main != responsibility.identity.uuid,
                  Set(actual.origins.keys) == Set(applied.origins.keys).subtracting([responsibility.identity.uuid]),
                  actual.origins.allSatisfy({ applied.origins[$0.key] == $0.value }) else {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            var confirmed = self
            confirmed.preDisableLayout = applied
            confirmed.applied = actual
            confirmed.layoutPending = baseline != actual
            confirmed.phase = .owned
            do { try confirmed.validate() }
            catch {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            self = confirmed
            return
        }
        if let responsibility = internalDisplay,
           responsibility.baseline, !responsibility.applied, responsibility.pending {
            guard phase == .applying, version == 2 || version == 3,
                  !sourceUnresolved,
                  internalEnabled == false,
                  actual.main == applied.main,
                  actual.main != responsibility.identity,
                  Set(actual.origins.keys) == Set(applied.origins.keys).subtracting([responsibility.identity]),
                  actual.origins.allSatisfy({ applied.origins[$0.key] == $0.value }) else {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            var confirmed = self
            confirmed.preDisableLayout = applied
            confirmed.applied = actual
            confirmed.layoutPending = baseline != actual
            confirmed.phase = .owned
            do { try confirmed.validate() }
            catch {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            self = confirmed
            return
        }
        guard actual == applied,
              internalDisplay.map({ internalEnabled == $0.applied }) ?? true,
              externalDisplay.map({ externalEnabled == $0.applied }) ?? true else {
            sourceUnresolved = true
            throw RecoveryError.unresolvedSource
        }
        phase = .owned
    }

    public mutating func observe(_ actual: DisplayLayout, source: ConfigurationSource) throws {
        guard phase == .owned else {
            // 提交和恢复期间的读回不能成为用户基准。
            if actual != applied && actual != baseline { sourceUnresolved = true }
            return
        }
        let present = Set(actual.origins.keys)
        let recorded = Set(baseline.origins.keys)
        if source == .reconnect, actual == applied {
            layoutPending = baseline != applied
            return
        }
        if present != recorded {
            guard source != .confirmedUser, present.isSubset(of: recorded) else {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            if externalDisplay != nil, source == .unknown {
                sourceUnresolved = true
                throw RecoveryError.unresolvedSource
            }
            return
        }
        if actual == applied {
            layoutPending = baseline != applied
            return
        }
        if actual == preDisableLayout, actual != baseline {
            sourceUnresolved = true
            throw RecoveryError.unresolvedSource
        }
        if !layoutPending && actual == baseline && source != .confirmedUser { return }
        if actual == baseline, source == .reconnect, !sourceUnresolved {
            // 重连读回旧基准只解除已验证的布局责任，不生成新的基准。
            layoutPending = false
            return
        }
        guard source == .confirmedUser,
              Set(actual.origins.keys) == Set(baseline.origins.keys) else {
            sourceUnresolved = true
            throw RecoveryError.unresolvedSource
        }
        baseline = actual
        layoutPending = false
        sourceUnresolved = false
    }

    public mutating func observeInternalEnabled(_ actual: Bool, source: ConfigurationSource) throws {
        guard var responsibility = internalDisplay else { return }
        if actual == responsibility.applied {
            if phase == .owned {
                responsibility.pending = responsibility.baseline != responsibility.applied
                internalDisplay = responsibility
            }
            return
        }
        if !responsibility.pending && actual == responsibility.baseline { return }
        guard phase == .owned, source == .confirmedUser else {
            sourceUnresolved = true
            throw RecoveryError.unresolvedSource
        }
        responsibility.baseline = actual
        responsibility.pending = false
        internalDisplay = responsibility
    }

    public mutating func confirmExternalUserLayout(
        _ actual: DisplayLayout, internalEnabled: Bool, externalEnabled: Bool
    ) throws {
        try validate()
        guard let responsibility = externalDisplay, internalDisplay == nil,
              phase == .owned || phase == .restoring || (phase == .restored && canClear),
              internalEnabled, externalEnabled,
              Set(actual.origins.keys) == Set(baseline.origins.keys),
              actual != preDisableLayout || actual == baseline else { throw RecoveryError.unresolvedSource }
        var confirmed = self
        confirmed.baseline = actual
        confirmed.layoutPending = false
        confirmed.externalDisplay = ExternalDisplayResponsibility(
            identity: responsibility.identity, numericIDHint: responsibility.numericIDHint,
            baseline: true, applied: responsibility.applied
        )
        confirmed.externalDisplay?.pending = false
        confirmed.sourceUnresolved = false
        confirmed.phase = .owned
        try confirmed.validate()
        self = confirmed
    }

    public mutating func observeExternalEnabled(_ actual: Bool, source: ConfigurationSource) throws {
        guard var responsibility = externalDisplay else { return }
        if actual == responsibility.applied {
            if phase == .owned {
                responsibility.pending = responsibility.baseline != responsibility.applied
                externalDisplay = responsibility
            }
            return
        }
        if !responsibility.pending && actual == responsibility.baseline { return }
        guard phase == .owned, source == .confirmedUser else {
            sourceUnresolved = true
            throw RecoveryError.unresolvedSource
        }
        responsibility.baseline = actual
        responsibility.pending = false
        externalDisplay = responsibility
    }

    public mutating func prepareReapplication(current: DisplayLayout, target: DisplayLayout) throws {
        guard phase == .owned, !sourceUnresolved else { throw RecoveryError.unfinishedTransaction }
        guard current == applied || (!layoutPending && current == baseline)
                || (externalDisplay != nil && current == preDisableLayout),
              Set(target.origins.keys) == Set(baseline.origins.keys),
              externalDisplay.map({ target.main != $0.identity.uuid }) ?? true,
              generation < UInt64.max else { throw RecoveryError.unresolvedSource }
        generation += 1
        applied = target
        preDisableLayout = nil
        layoutPending = baseline != target
        if var responsibility = internalDisplay {
            responsibility.pending = responsibility.baseline != responsibility.applied
            internalDisplay = responsibility
        }
        if var responsibility = externalDisplay {
            responsibility.pending = responsibility.baseline != responsibility.applied
            externalDisplay = responsibility
        }
        independentGuardVerified = nil
        phase = .prepared
    }

    public mutating func beginRestoration() {
        independentGuardVerified = nil
        phase = .restoring
    }

    public mutating func confirmIndependentGuardVerification() throws {
        try validate()
        guard canClear, internalDisplay != nil, externalDisplay == nil else { throw RecoveryError.invalidTransition }
        independentGuardVerified = true
        try validate()
    }

    public func layoutRestorePlan(connected: [ConnectedDisplay], current: DisplayLayout) throws -> LayoutRestorePlan {
        guard Set(connected.map(\.identity)).count == connected.count,
              Set(connected.map(\.numericID)).count == connected.count,
              connected.allSatisfy({ $0.numericID != 0 }) else { throw RecoveryError.identityConflict }
        guard !sourceUnresolved else { throw RecoveryError.unresolvedSource }
        guard layoutPending else {
            guard current == baseline else { throw RecoveryError.unresolvedSource }
            return LayoutRestorePlan(origins: [:], missing: [])
        }
        let present = Set(current.origins.keys)
        guard present == Set(connected.map(\.identity)),
              present.isSubset(of: Set(baseline.origins.keys)) else { throw RecoveryError.unresolvedSource }
        let mapping = Dictionary(uniqueKeysWithValues: connected.map { ($0.identity, $0.numericID) })
        let missing = Set(baseline.origins.keys).subtracting(mapping.keys)
        if current == baseline { return LayoutRestorePlan(origins: [:], missing: []) }
        let expectedApplied = preDisableLayout ?? applied
        guard current.main == expectedApplied.main || !present.contains(expectedApplied.main),
              let applicationOrigin = expectedApplied.origins[current.main] else { throw RecoveryError.unresolvedSource }
        for (identity, position) in current.origins {
            guard let expected = expectedApplied.origins[identity],
                  Int64(position.x) == Int64(expected.x) - Int64(applicationOrigin.x),
                  Int64(position.y) == Int64(expected.y) - Int64(applicationOrigin.y) else {
                throw RecoveryError.unresolvedSource
            }
        }
        let applicable = baseline.origins.filter { mapping[$0.key] != nil }
        // 原主屏缺失时，仅平移适用部分，缺失布局组责任仍保留。
        let origin = mapping[baseline.main] != nil ? DisplayOrigin(x: 0, y: 0) : applicable[current.main]
        var origins: [UInt32: DisplayOrigin] = [:]
        if let origin {
            for (identity, position) in applicable {
                guard let x = Int32(exactly: Int64(position.x) - Int64(origin.x)),
                      let y = Int32(exactly: Int64(position.y) - Int64(origin.y)),
                      let id = mapping[identity] else { throw RecoveryError.invalidRecord }
                origins[id] = DisplayOrigin(x: x, y: y)
            }
        }
        return LayoutRestorePlan(origins: origins, missing: missing)
    }

    public func internalRestorePlan(connected: [ConnectedDisplay]) throws -> (id: UInt32, enabled: Bool)? {
        guard let responsibility = internalDisplay, responsibility.pending else { return nil }
        guard Set(connected.map(\.identity)).count == connected.count,
              Set(connected.map(\.numericID)).count == connected.count,
              connected.allSatisfy({ $0.numericID != 0 }) else { throw RecoveryError.identityConflict }
        guard let display = connected.first(where: { $0.identity == responsibility.identity }) else { return nil }
        return (display.numericID, responsibility.baseline)
    }

    public func externalRestorePlan(connected: [ConnectedDisplay]) throws -> (id: UInt32, enabled: Bool)? {
        guard let responsibility = externalDisplay, responsibility.pending else { return nil }
        guard Set(connected.map(\.identity)).count == connected.count,
              Set(connected.map(\.numericID)).count == connected.count,
              connected.allSatisfy({ $0.numericID != 0 }) else { throw RecoveryError.identityConflict }
        guard let display = connected.first(where: { $0.identity == responsibility.identity.uuid }) else { return nil }
        return (display.numericID, responsibility.baseline)
    }

    public mutating func confirmRestored(
        actual: DisplayLayout,
        internalEnabled: Bool? = nil,
        externalEnabled: Bool? = nil
    ) throws {
        guard phase == .restoring else { throw RecoveryError.invalidTransition }
        guard actual == baseline else { throw RecoveryError.unfinishedTransaction }
        layoutPending = false
        if var responsibility = internalDisplay {
            guard internalEnabled == responsibility.baseline else { throw RecoveryError.unfinishedTransaction }
            responsibility.pending = false
            internalDisplay = responsibility
        }
        if var responsibility = externalDisplay {
            guard internalEnabled == true,
                  externalEnabled == responsibility.baseline else { throw RecoveryError.unfinishedTransaction }
            responsibility.pending = false
            externalDisplay = responsibility
        }
        guard !sourceUnresolved || actual == baseline else { throw RecoveryError.unresolvedSource }
        phase = .restored
        sourceUnresolved = false
    }

    public mutating func resumeInternalObservation(current: DisplayLayout, internalEnabled: Bool) throws {
        try validate()
        guard canClear,
              externalDisplay == nil,
              let responsibility = internalDisplay,
              responsibility.baseline, !responsibility.applied,
              responsibility.hardwareIdentity != nil else { throw RecoveryError.invalidTransition }
        guard current == baseline, internalEnabled else { throw RecoveryError.unresolvedSource }

        var resumed = self
        resumed.independentGuardVerified = nil
        resumed.phase = .owned
        try resumed.validate()
        self = resumed
    }
}
