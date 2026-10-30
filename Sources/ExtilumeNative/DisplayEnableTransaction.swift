import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

enum DisplayEnableTransactionError: Error, Equatable {
    case symbolUnavailable
    case invalidDisplay
    case beginFailed
    case configurationFailed
    case commitFailed
    case unsafeTopology
}

// 私有 ABI 参考 displayplacer/src/Header.h；符号存在不表示本机启停已经验收。
final class DisplayEnableTransaction {
    typealias Trace = (InternalLifecycleStage, CGError?) -> Void
    typealias NativeCall = (() -> CGError) throws -> CGError
    typealias Begin = (UnsafeMutablePointer<CGDisplayConfigRef?>) -> CGError
    typealias Configure = (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    typealias Complete = (CGDisplayConfigRef, CGConfigureOption) -> CGError
    typealias Cancel = (CGDisplayConfigRef) -> CGError
    private typealias NativeConfigure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private let library: UnsafeMutableRawPointer?
    private let configure: Configure?
    private let begin: Begin
    private let complete: Complete
    private let origin: (CGDisplayConfigRef, UInt32, Int32, Int32) -> CGError
    private let cancel: Cancel

    init() throws {
        guard let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL) else {
            throw DisplayEnableTransactionError.symbolUnavailable
        }
        guard let symbol = dlsym(library, "CGSConfigureDisplayEnabled") else {
            dlclose(library)
            throw DisplayEnableTransactionError.symbolUnavailable
        }
        self.library = library
        let function = unsafeBitCast(symbol, to: NativeConfigure.self)
        configure = { function($0, $1, $2) }
        begin = { CGBeginDisplayConfiguration($0) }
        complete = { CGCompleteDisplayConfiguration($0, $1) }
        cancel = { CGCancelDisplayConfiguration($0) }
        origin = { CGConfigureDisplayOrigin($0, $1, $2, $3) }
    }

    init(configure: Configure?, begin: @escaping Begin,
         complete: @escaping Complete, cancel: @escaping Cancel,
         origin: @escaping (CGDisplayConfigRef, UInt32, Int32, Int32) -> CGError = { CGConfigureDisplayOrigin($0, $1, $2, $3) }) {
        library = nil
        self.configure = configure
        self.begin = begin
        self.complete = complete
        self.cancel = cancel
        self.origin = origin
    }

    deinit {
        if let library { dlclose(library) }
    }

    // 持锁执行者提供已落盘的 applying 记录；checkProtection 须核验独立恢复能力和当前存活。
    func disableInternal(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        snapshotReader: () throws -> Snapshot,
        lidIsOpen: () -> Bool,
        checkProtection: (RecoveryRecord) throws -> Void,
        trace: @escaping Trace = { _, _ in },
        nativeCall: NativeCall = { $0() },
        completionCall: NativeCall? = nil,
        internalReader: (UUID) throws -> InternalDisplayState = { _ in throw RecoveryError.identityConflict }
    ) throws {
        try record.validate()
        guard record.phase == .applying, !record.sourceUnresolved,
              let responsibility = record.internalDisplay,
              responsibility.baseline, !responsibility.applied, responsibility.pending,
              let hardwareIdentity = responsibility.hardwareIdentity else {
            throw RecoveryError.invalidRecord
        }
        func observe() throws -> (Snapshot, InternalDisplayState) {
            let raw = try snapshotReader()
            let state = try internalReader(responsibility.identity)
            guard state.isEnabled else { throw RecoveryError.identityConflict }
            let snapshot = try raw.canonicalizingInternalDisplay(
                identity: responsibility.identity, hardwareIdentity: hardwareIdentity, state: state
            )
            return (snapshot, state)
        }
        let (initial, _) = try observe()
        guard initial.assessment.isSupported, try initial.layout() == record.applied else {
            throw DisplayEnableTransactionError.unsafeTopology
        }
        let initialConnections = try initial.connected()
        let display = try initial.builtInDisplay(identity: responsibility.identity).id
        try setEnabled(display: display, enabled: false, trace: trace, nativeCall: nativeCall, completionCall: completionCall) {
            try checkProtection(record)
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let (snapshot, state) = try observe()
            guard snapshot.assessment.isSupported, lidIsOpen(),
                  snapshot.displays.filter({ $0.identity == .builtIn }).count == 1,
                  try snapshot.builtInDisplay(identity: responsibility.identity).id == display,
                  try snapshot.connected().allSatisfy({ initialConnections.contains($0) }),
                  snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain && $0.id != kCGNullDirectDisplay }),
                  try snapshot.layout() == record.applied else {
                throw DisplayEnableTransactionError.unsafeTopology
            }
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            guard state.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity),
                  state.id == display, state.isEnabled else {
                throw RecoveryError.identityConflict
            }
            try checkProtection(record)
        }
    }

    // 持锁恢复执行者负责确认读回；启用不依赖仍连接的外屏或就绪保护。
    func enableInternalForRecovery(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        trace: @escaping Trace = { _, _ in },
        nativeCall: NativeCall = { $0() },
        internalReader: (UUID) throws -> InternalDisplayState
    ) throws {
        try record.validate()
        guard record.phase == .restoring, let responsibility = record.internalDisplay,
              responsibility.baseline, responsibility.pending else { throw RecoveryError.invalidRecord }
        func readInternal() throws -> InternalDisplayState {
            trace(.enableIdentityReadStarted, nil)
            let state = try internalReader(responsibility.identity)
            trace(.enableIdentityReadFinished, nil)
            return state
        }
        let initial = try readInternal()
        guard initial.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity) else { throw RecoveryError.identityConflict }
        let display = initial.id
        try setEnabled(display: display, enabled: true, trace: trace, nativeCall: nativeCall) {
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let actual = try readInternal()
            guard actual.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity),
                  actual.id == display, actual.reportedIdentityUUID == initial.reportedIdentityUUID else {
                throw RecoveryError.identityConflict
            }
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        }
    }

    func disableExternal(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        snapshotReader: () throws -> Snapshot,
        externalReader: () throws -> ExternalDisplayState,
        lidIsOpen: () -> Bool,
        checkAccess: () throws -> Void,
        nativeCall: NativeCall = { $0() }
    ) throws {
        try record.validate()
        guard record.phase == .applying, !record.sourceUnresolved,
              record.internalDisplay == nil, let responsibility = record.externalDisplay,
              responsibility.baseline, !responsibility.applied, responsibility.pending else {
            throw RecoveryError.invalidRecord
        }
        let initial = try snapshotReader()
        let state = try externalReader()
        let builtIns = initial.displays.filter { $0.identity == .builtIn && $0.isOnline && $0.isActive }
        guard initial.assessment.isSupported, initial.displays.count == 2,
              builtIns.count == 1, let internalID = builtIns.first?.identityUUID,
              state.identity == responsibility.identity, state.isEnabled,
              initial.displays.contains(where: { $0.id == state.id && $0.identityUUID == state.identity.uuid && $0.identity == .physical }),
              try initial.layout() == record.baseline || initial.layout() == record.applied,
              try layoutByMakingMain(initial.layout(), target: internalID) == record.applied else {
            throw DisplayEnableTransactionError.unsafeTopology
        }
        let connections = try initial.connected()
        try setEnabled(display: state.id, enabled: false, nativeCall: nativeCall,
                       prepareConfiguration: { configuration in
            for connection in connections {
                guard let position = record.applied.origins[connection.identity],
                      try nativeCall({ self.origin(configuration, connection.numericID, position.x, position.y) }) == .success else {
                    throw DisplayEnableTransactionError.configurationFailed
                }
            }
        }) {
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            guard lidIsOpen(), try snapshotReader() == initial,
                  try externalReader() == state else { throw DisplayEnableTransactionError.unsafeTopology }
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        }
    }

    func enableExternalForRecovery(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        externalReader: () throws -> ExternalDisplayState,
        checkAccess: () throws -> Void = {},
        nativeCall: NativeCall = { $0() },
        completionCall: NativeCall? = nil
    ) throws {
        try record.validate()
        guard record.phase == .restoring, record.internalDisplay == nil,
              let responsibility = record.externalDisplay, responsibility.baseline,
              responsibility.pending else { throw RecoveryError.invalidRecord }
        let initial = try externalReader()
        guard initial.identity == responsibility.identity else { throw RecoveryError.identityConflict }
        try setEnabled(display: initial.id, enabled: true, nativeCall: nativeCall, completionCall: completionCall) {
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let actual = try externalReader()
            guard actual.identity == responsibility.identity, actual.id == initial.id else {
                throw RecoveryError.identityConflict
            }
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        }
    }

    // 只由当次连接确认后的持锁恢复入口调用；不替代停用、DDC 或最终身份核验。
    func enableExternalConnectionForRecovery(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        observationReader: () throws -> ExternalRecoveryObservation,
        checkAccess: () throws -> Void,
        nativeCall: NativeCall = { $0() },
        completionCall: NativeCall? = nil
    ) throws {
        try record.validate()
        guard record.phase == .restoring, record.internalDisplay == nil,
              let responsibility = record.externalDisplay, responsibility.baseline,
              responsibility.pending else { throw RecoveryError.invalidRecord }
        let initial = try observationReader()
        guard case .connection(let evidence) = initial, evidence.isDisabled,
              initial.matches(identity: responsibility.identity, numericIDHint: responsibility.numericIDHint) else {
            throw RecoveryError.identityConflict
        }
        try setEnabled(display: evidence.id, enabled: true, nativeCall: nativeCall, completionCall: completionCall) {
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let actual = try observationReader()
            guard actual.matches(identity: responsibility.identity, numericIDHint: responsibility.numericIDHint) else {
                throw RecoveryError.identityConflict
            }
            if case .identified(let state) = actual, state.id != evidence.id { throw RecoveryError.identityConflict }
            try checkAccess()
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        }
    }

    // 仅由持锁控制／恢复入口调用；调用方须校验落盘责任、身份和适用保护。
    func setEnabled(
        display: CGDirectDisplayID, enabled: Bool,
        trace: @escaping Trace = { _, _ in }, nativeCall: NativeCall = { $0() },
        completionCall: NativeCall? = nil,
        prepareConfiguration: (CGDisplayConfigRef) throws -> Void = { _ in }, validate: () throws -> Void
    ) throws {
        guard display != kCGNullDirectDisplay else { throw DisplayEnableTransactionError.invalidDisplay }
        guard let configure else { throw DisplayEnableTransactionError.symbolUnavailable }
        trace(.enablePreValidationStarted, nil)
        try validate()
        trace(.enablePreValidationFinished, nil)
        var configuration: CGDisplayConfigRef?
        let beginResult = try nativeCall {
            trace(.enableBeginStarted, nil)
            return begin(&configuration)
        }
        trace(.enableBeginFinished, beginResult)
        guard beginResult == .success, let configuration else {
            throw DisplayEnableTransactionError.beginFailed
        }
        var consumed = false
        defer {
            if !consumed {
                trace(.enableCancelStarted, nil)
                let cancelResult = cancel(configuration)
                trace(.enableCancelFinished, cancelResult)
            }
        }
        try prepareConfiguration(configuration)
        let configureResult = try nativeCall {
            trace(.enableConfigureStarted, nil)
            return configure(configuration, display, enabled)
        }
        trace(.enableConfigureFinished, configureResult)
        guard configureResult == .success else {
            throw DisplayEnableTransactionError.configurationFailed
        }
        trace(.enablePostValidationStarted, nil)
        try validate()
        trace(.enablePostValidationFinished, nil)
        func invokeCompletion() -> CGError {
            let result = complete(configuration, enabled ? .forSession : .forAppOnly)
            // 外层门禁在 Complete 返回后仍可能失败；已消费句柄不能再取消。
            consumed = true
            return result
        }
        trace(.enableCompleteStarted, nil)
        let result: CGError
        if let completionCall { result = try completionCall(invokeCompletion) }
        else { result = try nativeCall(invokeCompletion) }
        trace(.enableCompleteFinished, result)
        guard result == .success else { throw DisplayEnableTransactionError.commitFailed }
    }
}
