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
    typealias Begin = (UnsafeMutablePointer<CGDisplayConfigRef?>) -> CGError
    typealias Configure = (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    typealias Complete = (CGDisplayConfigRef, CGConfigureOption) -> CGError
    typealias Cancel = (CGDisplayConfigRef) -> CGError
    private typealias NativeConfigure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private let library: UnsafeMutableRawPointer?
    private let configure: Configure?
    private let begin: Begin
    private let complete: Complete
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
    }

    init(configure: Configure?, begin: @escaping Begin,
         complete: @escaping Complete, cancel: @escaping Cancel) {
        library = nil
        self.configure = configure
        self.begin = begin
        self.complete = complete
        self.cancel = cancel
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
        checkProtection: (RecoveryRecord) throws -> Void
    ) throws {
        try record.validate()
        guard record.phase == .applying, !record.sourceUnresolved,
              let responsibility = record.internalDisplay,
              responsibility.baseline, !responsibility.applied, responsibility.pending else {
            throw RecoveryError.invalidRecord
        }
        let initial = try snapshotReader()
        guard initial.assessment.isSupported, try initial.layout() == record.applied else {
            throw DisplayEnableTransactionError.unsafeTopology
        }
        let initialConnections = try initial.connected()
        let display = try initial.builtInDisplay(identity: responsibility.identity).id
        try setEnabled(display: display, enabled: false) {
            try checkProtection(record)
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let snapshot = try snapshotReader()
            guard snapshot.assessment.isSupported, lidIsOpen(),
                  snapshot.displays.filter({ $0.identity == .builtIn }).count == 1,
                  try snapshot.builtInDisplay(identity: responsibility.identity).id == display,
                  try snapshot.connected().allSatisfy({ initialConnections.contains($0) }),
                  snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain && $0.id != kCGNullDirectDisplay }),
                  try snapshot.layout() == record.applied else {
                throw DisplayEnableTransactionError.unsafeTopology
            }
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            try checkProtection(record)
        }
    }

    // 持锁恢复执行者负责确认读回；启用不依赖仍连接的外屏或就绪保护。
    func enableInternalForRecovery(
        record: RecoveryRecord,
        loadRecord: () throws -> RecoveryRecord?,
        snapshotReader: () throws -> Snapshot
    ) throws {
        try record.validate()
        guard record.phase == .restoring, let responsibility = record.internalDisplay,
              responsibility.baseline, responsibility.pending else { throw RecoveryError.invalidRecord }
        let initial = try snapshotReader()
        let display = try initial.builtInDisplay(identity: responsibility.identity).id
        try setEnabled(display: display, enabled: true) {
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
            let snapshot = try snapshotReader()
            guard try snapshot.builtInDisplay(identity: responsibility.identity).id == display else {
                throw RecoveryError.identityConflict
            }
            guard try loadRecord() == record else { throw RecoveryError.unfinishedTransaction }
        }
    }

    // 调用方须校验已落盘责任、身份、拓扑和独立保护；当前没有真实启停入口。
    func setEnabled(display: CGDirectDisplayID, enabled: Bool, validate: () throws -> Void) throws {
        guard display != kCGNullDirectDisplay else { throw DisplayEnableTransactionError.invalidDisplay }
        guard let configure else { throw DisplayEnableTransactionError.symbolUnavailable }
        try validate()
        var configuration: CGDisplayConfigRef?
        guard begin(&configuration) == .success, let configuration else {
            throw DisplayEnableTransactionError.beginFailed
        }
        var consumed = false
        defer { if !consumed { _ = cancel(configuration) } }
        guard configure(configuration, display, enabled) == .success else {
            throw DisplayEnableTransactionError.configurationFailed
        }
        try validate()
        let result = complete(configuration, enabled ? .forSession : .forAppOnly)
        consumed = true // Complete 返回后句柄已失效，包括失败返回。
        guard result == .success else { throw DisplayEnableTransactionError.commitFailed }
    }
}
