import CoreGraphics
import CoreFoundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import ExtilumeCore
import Foundation

setlinebuf(stdout) // 辅助进程共享管道时，逐行证据须及时可见。

struct DisplayState: Equatable, Codable {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let identityUUID: UUID?
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

private let coreDisplayLibrary = dlopen(
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
    RTLD_LAZY | RTLD_LOCAL
)
// 私有只读符号不可用时，外接显示器身份保持 unknown。
private let coreDisplayCreateInfo: CoreDisplayCreateInfo? = {
    guard let coreDisplayLibrary,
          let symbol = dlsym(coreDisplayLibrary, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(symbol, to: CoreDisplayCreateInfo.self)
}()

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

    var description: String {
        switch self {
        case .displayListReadFailed(let list): "CoreGraphics 无法读取\(list)显示列表"
        case .noDisplays(let list): "CoreGraphics 返回的\(list)显示列表为空"
        case .displayModeReadFailed: "CoreGraphics 无法读取当前显示模式"
        case .noHDMIService: "没有唯一匹配的物理 HDMI 设备"
        }
    }
}

private func displayList(_ name: String, read: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard read(0, nil, &count) == .success else { throw ProbeError.displayListReadFailed(name) }
    guard count > 0 else { throw ProbeError.noDisplays(name) }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var actualCount = count
    let result = ids.withUnsafeMutableBufferPointer { buffer in
        read(UInt32(buffer.count), buffer.baseAddress, &actualCount)
    }
    guard result == .success else { throw ProbeError.displayListReadFailed(name) }
    guard actualCount > 0 else { throw ProbeError.noDisplays(name) }
    return Array(ids.prefix(Int(actualCount)))
}

func readSnapshot() throws -> Snapshot {
    let online = try displayList("在线", read: CGGetOnlineDisplayList)
    let active = try displayList("活动", read: CGGetActiveDisplayList)
    let onlineSet = Set(online)
    let activeSet = Set(active)
    let mainID = CGMainDisplayID()
    let candidates = registryEvidence()

    let states = try Set(online + active).map { id -> DisplayState in
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

private func issueDescription(_ issue: ScopeIssue) -> String {
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
    lines.append("本次只读运行未执行显示配置写入。主屏验证须显式指定 --verify-primary；内屏停用未实现。")
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

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
    print("""
    只读：extilume-probe
    主屏验证：extilume-probe --verify-primary <0700 状态目录>
    补偿恢复：extilume-probe --recover-primary <同一状态目录>
    退出后独立核对并清除：extilume-probe --finalize-primary <同一状态目录>
    已手动修改 C、原进程退出后确认来源：extilume-probe --confirm-user-primary <同一状态目录>
    不改显示设置的保护演练：extilume-probe --guard-drill <0700 状态目录>
    只读物理事件观察：extilume-probe --watch-connection（mark / stop）
    验证命令：status、confirm-user（仅在你已手动修改布局后）、reapply、stop。
    内屏停用未实现。主动验证尚需开盖实机验收。
    """)
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--watch-connection" {
    do {
        let observer = try ConnectionObserver(service: matchedHDMIService())
        try observer.start()
        print("只读 HDMI 事件观察已启动；mark 仅人工标记，stop 结束。不修改显示设置。")
        DispatchQueue.global().async {
            while let command = readLine() { observer.command(command) }
            observer.command("stop")
        }
        withExtendedLifetime(observer) { CFRunLoopRun() }
    } catch {
        fputs("HDMI 物理事件观察未就绪；未执行配置写入。\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--display-snapshot",
          let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3 {
    do { try serveSnapshot(descriptor: descriptor) }
    catch {
        fputs("独立显示读回未完成；未执行配置写入。\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--display-guard",
          let descriptor = Int32(CommandLine.arguments[3]), descriptor >= 3 {
    do {
        let guardProcess = try DisplayGuard(directory: URL(fileURLWithPath: CommandLine.arguments[2]), descriptor: descriptor)
        try guardProcess.start()
        withExtendedLifetime(guardProcess) { CFRunLoopRun() }
    } catch {
        fputs("辅助进程未就绪；未授权任何内屏停用。责任记录保留。\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--guard-drill" {
    do {
        let drill = try GuardDrill(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        try drill.start()
        withExtendedLifetime(drill) { CFRunLoopRun() }
    } catch {
        fputs("保护演练未完成；显示配置未写入，已有责任保留。\n", stderr)
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
            try controller.start()
            withExtendedLifetime(controller) { CFRunLoopRun() }
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
        fputs("Extilume 本机显示只读探测\n运行模式：只读\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n架构：\(architectureName())\n内屏开合：\(clamshellState())\n显示拓扑：不可读\n阻塞：\(error)。未执行显示配置写入。\n主动验证模式：主屏已实现；内屏停用未实现\n", stderr)
        exit(EXIT_FAILURE)
    }
}
