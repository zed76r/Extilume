import AppKit
import CoreGraphics
import CoreFoundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import ExtilumeCore
import Foundation

struct DisplayState: Equatable, Codable {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    var identityUUID: UUID?
    let isOnline: Bool
    let isActive: Bool
    let isMain: Bool
    let isMirrored: Bool
    let originX: CGFloat
    let originY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let rotation: Double
    let mode: DisplayModeState

    var observation: DisplayObservation {
        DisplayObservation(identity: identity, isOnline: isOnline, isActive: isActive, isMirrored: isMirrored)
    }
}

private typealias CoreDisplayCreateInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

// 动态库句柄初始化后只读，进程存活期间不关闭。
nonisolated(unsafe) private let coreDisplayLibrary = dlopen(
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
    RTLD_LAZY | RTLD_LOCAL
)
// 私有只读符号不可用时，外接显示器身份保持 unknown。
private let coreDisplayCreateInfo: CoreDisplayCreateInfo? = {
    guard let coreDisplayLibrary,
          let symbol = dlsym(coreDisplayLibrary, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(symbol, to: CoreDisplayCreateInfo.self)
}()

func coreDisplayRecoveryDiagnosticInfo(_ id: UInt32) -> [String: Any]? {
    guard id != 0 else { return nil }
    return coreDisplayCreateInfo?(id)?.takeRetainedValue() as? [String: Any]
}

private func registryEvidence() -> [DisplayRegistryEvidence] {
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOMobileFramebufferShim"),
        &iterator
    )
    guard status == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }

    var evidence: [DisplayRegistryEvidence] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == IO_OBJECT_NULL { break }
        defer { IOObjectRelease(service) }

        let transport = IORegistryEntryCreateCFProperty(
            service,
            "Transport" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
        let downstream = transport?["Downstream"] as? String

        var pathBuffer = [CChar](repeating: 0, count: 512)
        let pathStatus = pathBuffer.withUnsafeMutableBufferPointer {
            IORegistryEntryGetPath(service, kIOServicePlane, $0.baseAddress!)
        }
        let registryPath = pathStatus == KERN_SUCCESS
            ? pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : nil
        let edidUUID = IORegistryEntryCreateCFProperty(
            service,
            "EDID UUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String

        evidence.append(DisplayRegistryEvidence(
            downstream: downstream,
            registryPath: registryPath,
            edidUUID: edidUUID
        ))
    }
    return evidence
}

private func matchedDisplayUUID(_ id: CGDirectDisplayID, candidates: [DisplayRegistryEvidence]) -> UUID? {
    guard let info = coreDisplayCreateInfo?(id)?.takeRetainedValue() as? [String: Any] else { return nil }
    return matchPhysicalHDMIDisplayUUID(
        location: info["IODisplayLocation"] as? String,
        displayUUID: (info["DisplayUUID"] as? String) ?? (info["kCGDisplayUUID"] as? String),
        candidates: candidates
    )
}

private func builtInUUID(_ id: CGDirectDisplayID) -> UUID? {
    guard let info = coreDisplayCreateInfo?(id)?.takeRetainedValue() as? [String: Any],
          let value = (info["DisplayUUID"] as? String) ?? (info["kCGDisplayUUID"] as? String) else { return nil }
    return UUID(uuidString: value)
}

func matchedHDMIService() throws -> io_service_t {
    let snapshot = try readSnapshot()
    guard snapshot.assessment.isSupported,
          let display = snapshot.displays.first(where: { $0.identity == .physical }),
          let info = coreDisplayCreateInfo?(display.id)?.takeRetainedValue() as? [String: Any],
          let location = info["IODisplayLocation"] as? String,
          matchedDisplayUUID(display.id, candidates: registryEvidence()) == display.identityUUID else {
        throw ProbeError.noHDMIService
    }
    let service = IORegistryEntryFromPath(kIOMainPortDefault, location)
    guard service != IO_OBJECT_NULL else { throw ProbeError.noHDMIService }
    return service
}

struct DisplayModeState: Equatable, Codable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let ioDisplayModeID: Int32
}

struct Snapshot: Equatable, Codable {
    let displays: [DisplayState]

    var assessment: ScopeAssessment { assessScope(displays.map(\.observation)) }
}

private enum ProbeError: Error, CustomStringConvertible {
    case displayListReadFailed(String)
    case noDisplays(String)
    case displayModeReadFailed
    case noHDMIService
    case eventLoopUnavailable

    var description: String {
        switch self {
        case .displayListReadFailed(let list): "CoreGraphics 无法读取\(list)显示列表"
        case .noDisplays(let list): "CoreGraphics 返回的\(list)显示列表为空"
        case .displayModeReadFailed: "CoreGraphics 无法读取当前显示模式"
        case .noHDMIService: "没有唯一匹配的物理 HDMI 设备"
        case .eventLoopUnavailable: "无法启动后台显示事件循环"
        }
    }
}

// 仅输出固定分类，不插入底层错误描述或设备身份。
func snapshotWitnessFailureCode(_ error: Error) -> String {
    if error is ExternalConnectionRecoveryError { return "connection-confirmation-required" }
    if let error = error as? DisplayEnableTransactionError {
        switch error {
        case .symbolUnavailable: return "enable-symbol-unavailable"
        case .invalidDisplay: return "enable-invalid-display"
        case .beginFailed: return "enable-begin-failed"
        case .configurationFailed: return "enable-configure-failed"
        case .commitFailed: return "enable-complete-failed"
        case .unsafeTopology: return "enable-unsafe-topology"
        }
    }
    if let error = error as? ProbeError {
        switch error {
        case .displayListReadFailed("在线"): return "online-list"
        case .displayListReadFailed("活动"): return "active-list"
        default: return "display-read"
        }
    }
    if let error = error as? RecoveryError {
        switch error {
        case .identityConflict: return "identity-conflict"
        case .invalidRecord: return "recovery-invalid-record"
        case .unresolvedSource: return "recovery-unresolved-source"
        case .unfinishedTransaction: return "recovery-unfinished-transaction"
        case .invalidTransition: return "recovery-invalid-transition"
        }
    }
    if error is RecoveryStoreError { return "recovery-store" }
    if let error = error as? GuardChannelError {
        switch error {
        case .timedOut: return "channel-timeout"
        case .peerClosed: return "channel-closed"
        case .systemCall: return "channel-system-call"
        default: return "channel-invalid"
        }
    }
    if let error = error as? SnapshotWitnessError {
        switch error {
        case .spawnFailed: return "witness-spawn"
        case .communicationFailed: return "witness-communication"
        case .timedOut: return "witness-timeout"
        case .invalidSnapshot: return "witness-invalid-state"
        case .snapshotUnavailable: return "witness-unavailable"
        case .processFailed: return "witness-exit"
        case .cleanupFailed: return "witness-cleanup"
        case .internalStateChanged: return "internal-state-changed"
        case .internalInformationUnavailable: return "internal-information-unavailable"
        case .externalStateChanged: return "external-state-changed"
        }
    }
    return "unclassified"
}

private func displayList(_ name: String, read: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard read(0, nil, &count) == .success else { throw ProbeError.displayListReadFailed(name) }
    guard count > 0 else { return [] }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var actualCount = count
    let result = ids.withUnsafeMutableBufferPointer { buffer in
        read(UInt32(buffer.count), buffer.baseAddress, &actualCount)
    }
    guard result == .success else { throw ProbeError.displayListReadFailed(name) }
    return Array(ids.prefix(Int(actualCount)))
}

private func readInternalHardwareIdentity(_ info: [String: Any]) -> InternalDisplayHardwareIdentity? {
    var boot = [CChar](repeating: 0, count: 128)
    var size = boot.count
    guard sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0,
          size > 0, size <= boot.count, boot[size - 1] == 0,
          let bootSession = boot.withUnsafeBufferPointer({ UUID(uuidString: String(cString: $0.baseAddress!)) }),
          let location = info["IODisplayLocation"] as? String else { return nil }
    let service = IORegistryEntryFromPath(kIOMainPortDefault, location)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var entryID: UInt64 = 0
    guard IOObjectConformsTo(service, "IOMobileFramebufferShim") != 0,
          IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS, entryID != 0 else { return nil }
    return InternalDisplayHardwareIdentity(bootSession: bootSession, registryEntryID: entryID)
}

func internalDisplayReportedIdentity(
    in info: [String: Any]?, numericID: UInt32,
    diagnostic: (InternalDisplayCandidateFailure) -> Void
) -> UUID? {
    guard let info else { diagnostic(.informationUnavailable); return nil }
    guard (info["kCGDisplayID"] as? NSNumber)?.uint32Value == numericID else {
        diagnostic(.numericIDMismatch); return nil
    }
    guard let text = (info["DisplayUUID"] as? String) ?? (info["kCGDisplayUUID"] as? String) else {
        diagnostic(.missingUUID); return nil
    }
    guard let uuid = UUID(uuidString: text) else { diagnostic(.malformedUUID); return nil }
    return uuid
}

func readInternalDisplay(
    identity: UUID, numericIDHint: UInt32,
    hardwareIdentity: InternalDisplayHardwareIdentity? = nil
) throws -> InternalDisplayState {
    try hardwareIdentity?.validate()
    let bootSession: UUID?
    if hardwareIdentity != nil { bootSession = try currentBootSession() }
    else { bootSession = nil }
    traceInternalLifecycle(.internalOnlineReadStarted, role: .witness)
    let online = try displayList("在线", read: CGGetOnlineDisplayList)
    traceInternalLifecycle(.internalOnlineReadFinished, role: .witness)
    traceInternalLifecycle(.internalActiveReadStarted, role: .witness)
    let active = try displayList("活动", read: CGGetActiveDisplayList)
    traceInternalLifecycle(.internalActiveReadFinished, role: .witness)
    var identityFailure: InternalDisplayIdentityFailure?
    var numericHintFailure: InternalDisplayCandidateFailure?
    var otherCandidateFailure = false
    var builtInConflict = false
    var reportedIdentities = Set<UUID>()
    do {
        return try matchInternalDisplay(
            identity: identity, hardwareIdentity: hardwareIdentity, candidates: online + active + [numericIDHint],
            diagnostic: {
                identityFailure = $0
                traceInternalLifecycle(.internalIdentityRejected, role: .witness,
                                       succeeded: false, identityFailure: $0)
            }
        ) { id in
            traceInternalLifecycle(.internalCandidateReadStarted, role: .witness, isNumericHint: id == numericIDHint)
            let info = coreDisplayCreateInfo?(id)?.takeRetainedValue() as? [String: Any]
            traceInternalLifecycle(.internalCandidateReadFinished, role: .witness, isNumericHint: id == numericIDHint)
            var candidateFailure: InternalDisplayCandidateFailure?
            let uuid = internalDisplayReportedIdentity(in: info, numericID: id, diagnostic: { failure in
                candidateFailure = failure
                traceInternalLifecycle(.internalCandidateUnavailable, role: .witness,
                                       succeeded: false, candidateFailure: failure, isNumericHint: id == numericIDHint)
            })
            guard let uuid, let info else {
                if id == numericIDHint { numericHintFailure = candidateFailure }
                else if candidateFailure != nil { otherCandidateFailure = true }
                return nil
            }
            if !reportedIdentities.insert(uuid).inserted { otherCandidateFailure = true }
            let candidateHardware = readInternalHardwareIdentity(info)
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            if isBuiltIn && uuid != identity && candidateHardware != hardwareIdentity {
                builtInConflict = true
            }
            return InternalDisplayState(
                id: id, identityUUID: uuid, isBuiltIn: isBuiltIn,
                isOnline: CGDisplayIsOnline(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                hardwareIdentity: candidateHardware, reportedIdentityUUID: uuid
            )
        }
    } catch {
        if canReportInternalInformationUnavailable(
            identityFailure: identityFailure,
            numericHintFailure: numericHintFailure,
            otherCandidateFailure: otherCandidateFailure,
            builtInConflict: builtInConflict,
            hardwareIdentity: hardwareIdentity,
            currentBootSession: bootSession
        ) {
            throw SnapshotWitnessError.internalInformationUnavailable
        }
        throw error
    }
}

func readExternalDisplayState(_ id: UInt32) throws -> ExternalDisplayState? {
    guard id != 0,
          CGDisplayIsBuiltin(id) == 0,
          let info = coreDisplayCreateInfo?(id)?.takeRetainedValue() as? [String: Any],
          (info["kCGDisplayID"] as? NSNumber)?.uint32Value == id,
          let location = info["IODisplayLocation"] as? String, !location.isEmpty,
          let displayUUIDText = (info["DisplayUUID"] as? String) ?? (info["kCGDisplayUUID"] as? String),
          let displayUUID = UUID(uuidString: displayUUIDText) else { return nil }

    let evidence = registryEvidence()
    guard matchPhysicalHDMIDisplayUUID(
        location: location, displayUUID: displayUUIDText, candidates: evidence
    ) == displayUUID else { return nil }
    let pathMatches = evidence.filter { $0.registryPath == location }
    guard pathMatches.count == 1,
          let registry = pathMatches.first,
          registry.downstream == "HDMI",
          let edidUUID = registry.edidUUID, !edidUUID.isEmpty else { return nil }

    let service = IORegistryEntryFromPath(kIOMainPortDefault, location)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var registryEntryID: UInt64 = 0
    guard IOObjectConformsTo(service, "IOMobileFramebufferShim") != 0,
          IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS,
          registryEntryID != 0 else { return nil }

    let identity = ExternalDisplayIdentity(
        uuid: displayUUID,
        registryPath: location,
        edidUUID: edidUUID,
        bootSession: try currentBootSession(),
        registryEntryID: registryEntryID
    )
    try identity.validate()
    return ExternalDisplayState(
        id: id,
        identity: identity,
        isOnline: CGDisplayIsOnline(id) != 0,
        isActive: CGDisplayIsActive(id) != 0
    )
}

func readExternalDisplay(
    identity: ExternalDisplayIdentity,
    numericIDHint: UInt32
) throws -> ExternalDisplayState {
    let bootSession = try currentBootSession()
    guard identity.bootSession == bootSession else { throw RecoveryError.identityConflict }
    return try matchExternalDisplay(
        identity: identity,
        numericIDHint: numericIDHint,
        candidates: try displayList("在线", read: CGGetOnlineDisplayList)
            + displayList("活动", read: CGGetActiveDisplayList),
        privateCandidates: readPrivateDisplaySlots().displayIDs ?? [],
        currentBootSession: bootSession,
        read: readExternalDisplayState
    )
}

func readSnapshot(activeOnly: Bool = false) throws -> Snapshot {
    let online = try displayList("在线", read: CGGetOnlineDisplayList)
    let active = try displayList("活动", read: CGGetActiveDisplayList)
    guard !online.isEmpty else { throw ProbeError.noDisplays("在线") }
    guard !active.isEmpty else { throw ProbeError.noDisplays("活动") }
    let onlineSet = Set(online)
    let activeSet = Set(active)
    let mainID = CGMainDisplayID()
    let candidates = registryEvidence()

    let states = try Set(activeOnly ? active : online + active).map { id -> DisplayState in
        let bounds = CGDisplayBounds(id)
        guard let mode = CGDisplayCopyDisplayMode(id) else { throw ProbeError.displayModeReadFailed }
        let mirrored = CGDisplayIsInMirrorSet(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
        let isBuiltIn = CGDisplayIsBuiltin(id) != 0
        let identityUUID = isBuiltIn ? builtInUUID(id) : matchedDisplayUUID(id, candidates: candidates)
        return DisplayState(
            id: id,
            identity: isBuiltIn ? .builtIn : (identityUUID == nil ? .unknown : .physical),
            identityUUID: identityUUID,
            isOnline: onlineSet.contains(id) && CGDisplayIsOnline(id) != 0,
            isActive: activeSet.contains(id) && CGDisplayIsActive(id) != 0,
            isMain: id == mainID && mainID != kCGNullDirectDisplay,
            isMirrored: mirrored,
            originX: bounds.origin.x,
            originY: bounds.origin.y,
            width: bounds.width,
            height: bounds.height,
            rotation: CGDisplayRotation(id),
            mode: DisplayModeState(
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshRate: mode.refreshRate,
                ioDisplayModeID: mode.ioDisplayModeID
            )
        )
    }.sorted {
        if $0.identity != $1.identity { return $0.identity == .builtIn }
        if $0.originX != $1.originX { return $0.originX < $1.originX }
        if $0.originY != $1.originY { return $0.originY < $1.originY }
        return $0.id < $1.id
    }
    return Snapshot(displays: states)
}

func clamshellState() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return "未知" }
    defer { IOObjectRelease(service) }

    guard let property = IORegistryEntryCreateCFProperty(service, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
          CFGetTypeID(property) == CFBooleanGetTypeID() else { return "未知" }
    return CFBooleanGetValue(unsafeDowncast(property, to: CFBoolean.self)) ? "合盖" : "开盖"
}

func issueDescription(_ issue: ScopeIssue) -> String {
    switch issue {
    case .noDisplay: "没有可读显示器"
    case .noExternalDisplay: "没有外接显示器"
    case .multipleExternalDisplays: "检测到多台外接显示器"
    case .virtualExternalDisplay: "检测到虚拟外接显示器"
    case .unknownExternalIdentity: "外接显示器物理身份未知"
    case .externalNotOnline: "外接显示器未在线"
    case .externalNotActive: "外接显示器未处于活动桌面"
    case .mirrored: "检测到镜像显示"
    }
}

private func render(_ snapshot: Snapshot, unchanged: Bool) -> String {
    let activeCount = snapshot.displays.filter(\.isActive).count
    let onlineCount = snapshot.displays.filter(\.isOnline).count
    let main = snapshot.displays.first(where: \.isMain)
    var lines = [
        "Extilume 本机显示只读探测",
        "运行模式：只读",
        "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
        "架构：\(architectureName())",
        "内屏开合：\(clamshellState())",
        "在线显示器数：\(onlineCount)",
        "活动桌面显示器数：\(activeCount)",
        "主显示器：\(main.map { label(for: $0, in: snapshot.displays) } ?? "未知")",
        "桌面镜像：\(snapshot.displays.contains(where: \.isMirrored) ? "是" : "否")",
        "显示拓扑："
    ]

    var externalIndex = 0
    for display in snapshot.displays {
        let label: String
        if display.identity == .builtIn {
            label = "内屏"
        } else {
            externalIndex += 1
            label = "\(display.identity == .physical ? "HDMI" : "外屏") \(externalIndex)"
        }
        let identityLabel = display.identity == .builtIn ? "内置" : (display.identity == .physical ? "已确认物理 HDMI" : "未知")
        let linkLabel = display.identity == .physical ? "HDMI" : "未知"
        lines.append("- \(label)：身份=\(identityLabel)，在线=\(yesNo(display.isOnline))，活动=\(yesNo(display.isActive))，主屏=\(yesNo(display.isMain))，镜像=\(yesNo(display.isMirrored))，原点=(\(display.originX), \(display.originY))，连接链路=\(linkLabel)")
        lines.append("  当前模式=\(display.mode.width)×\(display.mode.height)，像素=\(display.mode.pixelWidth)×\(display.mode.pixelHeight)，刷新率=\(display.mode.refreshRate) Hz，旋转=\(display.rotation)°")
    }

    if snapshot.assessment.isSupported {
        lines.append("范围判定：支持当前拓扑")
    } else {
        lines.append("范围判定：不支持（\(snapshot.assessment.issues.map(issueDescription).joined(separator: "；"))）")
    }
    lines.append("启动前后布局、在线/活动、主屏、分辨率、旋转及显示模式读回一致：\(yesNo(unchanged))")
    lines.append("内屏启用位私有符号：\((try? DisplayEnableTransaction()) != nil ? "可解析（未调用，效果未验收）" : "不可用（禁止启停）")")
    lines.append("本次只读运行未执行显示配置写入。主动验证须显式指定对应入口；内屏停用效果尚未实机验收。")
    return lines.joined(separator: "\n")
}

private func label(for display: DisplayState, in displays: [DisplayState]) -> String {
    guard display.identity != .builtIn else { return "内屏" }
    let externalDisplays = displays.filter { $0.identity != .builtIn }
    let name = display.identity == .physical ? "HDMI" : "外屏"
    return "\(name) \((externalDisplays.firstIndex(of: display) ?? 0) + 1)"
}

private func yesNo(_ value: Bool) -> String { value ? "是" : "否" }

private func architectureName() -> String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "未知"
    #endif
}

@MainActor
private func displayEventApplication() throws -> NSApplication {
    let application = NSApplication.shared
    guard application.activationPolicy() == .prohibited || application.setActivationPolicy(.prohibited) else {
        throw ProbeError.eventLoopUnavailable
    }
    return application
}

@MainActor
private func recordConnectionTiming() throws -> Bool {
    let application = NSApplication.shared
    guard application.activationPolicy() == .accessory || application.setActivationPolicy(.accessory) else { throw ProbeError.eventLoopUnavailable }
    func writeLine(_ line: String) throws {
        guard fputs(line + "\n", stdout) >= 0, fflush(stdout) == 0 else {
            throw ProbeError.eventLoopUnavailable
        }
    }
    var markers = ConnectionTimingMarkers()
    let controller = ConnectionTimingWindowController(record: { action in
        let timestamp = try ContinuousClock.nanoseconds()
        var next = markers
        let line = try next.record(action, at: timestamp)
        try writeLine(line)
        markers = next
    }, finish: { application.stop(nil) })
    try writeLine(#"{"type":"manual-connection-session","event":"started","clock":"mach_continuous_time/ns"}"#)
    controller.showWindow(nil)
    application.activate(ignoringOtherApps: true)
    withExtendedLifetime(controller) { application.run() }
    let event = markers.isComplete ? "completed" : "incomplete"
    try writeLine("{\"type\":\"manual-connection-session\",\"event\":\"\(event)\"}")
    return markers.isComplete
}

@MainActor
private func recordRecoveryConfirmation(to path: String) throws -> Bool {
    let application = NSApplication.shared
    guard application.activationPolicy() == .accessory || application.setActivationPolicy(.accessory) else { throw ProbeError.eventLoopUnavailable }
    let controller = RecoveryConfirmationWindowController(record: {
        try captureRecoveryClock(to: path)
    }, finish: { application.stop(nil) })
    controller.showWindow(nil)
    application.activate(ignoringOtherApps: true)
    withExtendedLifetime(controller) { application.run() }
    return controller.recorded
}

@MainActor
public func runDisplayProbe() {
    do { if try runExternalDisplayInputProbeIfRequested() { return } }
    catch { exit(EXIT_FAILURE) }
    setlinebuf(stdout) // 辅助进程共享管道时，逐行证据须及时可见。
    if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
        print("""
        只读：extilume-probe
        外屏责任只读：extilume-probe --external-status <0700 状态目录>
        外屏恢复身份诊断（只读）：extilume-probe --diagnose-external-recovery <0700 状态目录>
        外屏停用原型（需当轮授权）：extilume-probe --verify-external-disable --allow-display-write <0700 独立状态目录>
        外屏恢复原型（需当轮授权）：extilume-probe --recover-external --allow-display-write <同一状态目录>
        主屏验证：extilume-probe --verify-primary <0700 状态目录>
        补偿恢复：extilume-probe --recover-primary <同一状态目录>
        退出后独立核对并清除：extilume-probe --finalize-primary <同一状态目录>
        已手动修改 C、原进程退出后确认来源：extilume-probe --confirm-user-primary <同一状态目录>
        不改显示设置的保护演练：extilume-probe --guard-drill <0700 状态目录>
        内屏恢复合同无写入演练：extilume-probe --guard-drill-internal <0700 状态目录>
        内屏责任独立恢复（记录保留）：extilume-probe --recover-internal <同一状态目录>
        受保护内屏停用验证（需先开盖且外屏为主屏）：extilume-probe --verify-internal-disable <0700 状态目录>
        只读物理事件观察：extilume-probe --watch-connection（mark / stop）
        离线计时检查：extilume-probe --check-recovery-timing <故障最早ns> <故障最晚ns> <通知ns> <恢复核验ns>
        同启动会话计时：extilume-probe --check-recovery-timing --clock-samples <故障前样本> <故障后样本> <通知样本> <恢复样本> [--suspension-evidence <休眠证据>]
        休眠证据评估：只有四个采集样本同启动会话时才允许扣除，裸数字入口只作算术检查
        只读时钟采样：extilume-probe --sample-recovery-clock <受限目录中的新文件>
        只读休眠证据采集：extilume-probe --record-suspension-evidence <受限目录中的新文件>（stop结束）
        人工恢复确认：extilume-probe --record-recovery-confirmation <受限目录中的新样本文件>
        人工动作计时窗口：extilume-probe --record-connection-timing（JSON 行输出；不读写显示状态）
        验证命令：status、confirm-user（仅在你已手动修改布局后）、reapply、stop。
        内屏停用验证命令：status、restore、confirm-user、reapply、stop。睡眠及完整故障恢复尚未实机验收。
        """)
    } else if ["--external-status", "--diagnose-external-recovery", "--verify-external-disable", "--recover-external"].contains(CommandLine.arguments.dropFirst().first ?? "") {
        do {
            guard let command = try ExternalVerificationCommand(arguments: Array(CommandLine.arguments.dropFirst())) else {
                throw ApplicationLaunchError.invalidArguments
            }
            try runExternalVerification(command)
        } catch {
            fputs("外屏验证未完成，类别=\(snapshotWitnessFailureCode(error))；保留责任，请只读核对后使用外屏恢复入口。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--external-display-snapshot",
              let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3 {
        do { try serveExternalDisplay(descriptor: descriptor) }
        catch { exit(EXIT_FAILURE) }
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--external-recovery-snapshot",
              let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3 {
        do { try serveExternalRecoveryObservation(descriptor: descriptor) }
        catch { exit(EXIT_FAILURE) }
    } else if CommandLine.arguments.dropFirst().first == "--record-suspension-evidence" {
        do {
            guard CommandLine.arguments.count == 3 else { throw RecoveryError.invalidRecord }
            try recordRecoverySuspensionEvidence(to: CommandLine.arguments[2])
            print("电源与配对时钟证据已受限保存；未操作睡眠或显示状态。")
        } catch {
            fputs("只读休眠证据采集未完成；不能据此宣称验收通过。未修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.dropFirst().first == "--sample-recovery-clock" {
        do {
            guard CommandLine.arguments.count == 3 else { throw RecoveryError.invalidRecord }
            try captureRecoveryClock(to: CommandLine.arguments[2])
            print("连续／暂停时钟样本已受限保存；未读取或修改显示状态。")
        } catch {
            fputs("时钟采样未完成；须提供受限目录内不存在的文件路径。未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.dropFirst().first == "--check-recovery-timing" {
        do { print(try recoveryTimingReport(arguments: Array(CommandLine.arguments.dropFirst(2)))) }
        catch {
            fputs("计时输入无效；须提供四个有序 UInt64 纳秒值，或四个同启动会话的采集样本。未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.dropFirst().first == "--record-recovery-confirmation" {
        guard CommandLine.arguments.count == 3, !CommandLine.arguments[2].isEmpty else {
            fputs("人工恢复确认须提供受限目录中的新样本文件；未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            guard try recordRecoveryConfirmation(to: CommandLine.arguments[2]) else {
                fputs("人工恢复确认未完成，不构成验收；已有文件不覆盖。\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("人工恢复确认的时钟样本已受限保存；仍需同轮故障计时与独立配置核验。")
        } catch {
            fputs("人工恢复确认未完成；未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.dropFirst().first == "--record-connection-timing" {
        guard CommandLine.arguments.count == 2 else {
            fputs("人工计时窗口不接受额外参数；未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            guard try recordConnectionTiming() else {
                fputs("人工动作记录未完成；保留已输出的部分记录，不构成验收。\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("人工计时记录失败；不构成验收，未读取或修改显示状态。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--watch-connection" {
        do {
            let application = try displayEventApplication()
            let observer = try ConnectionObserver(service: matchedHDMIService())
            try observer.start()
            print("只读 HDMI 事件观察已启动；mark 仅人工标记，stop 结束。不修改显示设置。")
            print("External 候选事件仅标记安全条件失效；不确认目标身份、拔线或可用桌面，不授权内屏停用。")
            DispatchQueue.global().async {
                while let command = readLine() { observer.command(command) }
                observer.command("stop")
            }
            withExtendedLifetime(observer) { application.run() }
        } catch {
            fputs("HDMI 物理事件观察未就绪；未执行配置写入。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recover-internal" {
        do {
            try recoverInternalRecord(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("内屏责任恢复及独立读回完成；记录保留，未自动清除。")
        } catch {
            traceInternalLifecycle(.restorationFailed, role: .recoveryEntry, succeeded: false, error: error)
            fputs("内屏责任恢复未完成，类别=\(snapshotWitnessFailureCode(error))；记录保留。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--internal-display-snapshot",
              let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3 {
        do { try serveInternalDisplay(descriptor: descriptor) }
        catch {
            fputs("独立内屏身份与启用位读回未完成，类别=\(snapshotWitnessFailureCode(error))；未执行配置写入。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3,
              ["--display-snapshot", "--active-display-snapshot"].contains(CommandLine.arguments[1]),
              let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3 {
        do { try serveSnapshot(descriptor: descriptor, activeOnly: CommandLine.arguments[1] == "--active-display-snapshot") }
        catch {
            fputs("独立显示读回未完成；未执行配置写入。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--display-guard",
              let descriptor = Int32(CommandLine.arguments[3]), descriptor >= 3 {
        do {
            let application = try displayEventApplication()
            let guardProcess = try DisplayGuard(directory: URL(fileURLWithPath: CommandLine.arguments[2]), descriptor: descriptor)
            DispatchQueue.main.async {
                do { try guardProcess.start() }
                catch {
                    fputs("辅助进程未就绪；未授权任何内屏停用。责任记录保留。\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            withExtendedLifetime(guardProcess) { application.run() }
        } catch {
            fputs("辅助进程未就绪；未授权任何内屏停用。责任记录保留。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3,
              ["--guard-drill", "--guard-drill-internal", "--verify-internal-disable"].contains(CommandLine.arguments[1]) {
        do {
            let application = try displayEventApplication()
            let operation: GuardSessionOperation = switch CommandLine.arguments[1] {
            case "--verify-internal-disable": .disableInternal
            case "--guard-drill-internal": .internalDrill
            default: .drill
            }
            let drill = try GuardSession(
                directory: URL(fileURLWithPath: CommandLine.arguments[2]),
                operation: operation
            )
            DispatchQueue.main.async {
                DispatchQueue.global().async {
                    do { try drill.start() }
                    catch {
                        fputs("验证会话未能启动；已有责任记录保留。\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                }
            }
            withExtendedLifetime(drill) { application.run() }
        } catch {
            if CommandLine.arguments[1] == "--verify-internal-disable" {
                fputs("停用验证未能启动；禁止新控制，已有责任记录保留。\n", stderr)
            } else {
                fputs("保护演练未完成；显示配置未写入，已有责任保留。\n", stderr)
            }
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count == 3,
              ["--verify-primary", "--recover-primary", "--finalize-primary", "--confirm-user-primary"].contains(CommandLine.arguments[1]) {
        do {
            let controller = try PrimaryController(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            if CommandLine.arguments[1] == "--confirm-user-primary" {
                try controller.confirmUserOnly()
            } else if CommandLine.arguments[1] == "--finalize-primary" {
                try controller.finalizeOnly()
            } else if CommandLine.arguments[1] == "--recover-primary" {
                try controller.recoverOnly()
            } else {
                let application = try displayEventApplication()
                try controller.start()
                withExtendedLifetime(controller) { application.run() }
            }
        } catch {
            fputs("主屏验证未完成；保留已有责任记录。未执行内屏停用。\n", stderr)
            exit(EXIT_FAILURE)
        }
    } else if CommandLine.arguments.count > 1 {
        fputs("参数无效；请查看 --help。\n", stderr)
        exit(EXIT_FAILURE)
    } else {
        do {
            let before = try readSnapshot()
            let after = try readSnapshot()
            print(render(after, unchanged: before == after))
        } catch {
            fputs("Extilume 本机显示只读探测\n运行模式：只读\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n架构：\(architectureName())\n内屏开合：\(clamshellState())\n显示拓扑：不可读\n阻塞：\(error)。未执行显示配置写入。\n主动验证模式：需显式指定；内屏停用效果尚未实机验收\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
