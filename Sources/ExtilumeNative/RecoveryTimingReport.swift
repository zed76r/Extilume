import Foundation
import Darwin
import ExtilumeCore

private enum RecoveryTimingReportError: Error { case invalidArguments }
private enum RecoveryClockCaptureError: Error { case invalidDestination, insecureDirectory, bootSessionUnavailable, writeFailed }

func recoveryTimingReport(arguments: [String]) throws -> String {
    let hasClockContext = arguments.first == "--clock-samples"
    let baseCount = hasClockContext ? 5 : 4
    let hasEvidence = arguments.count == baseCount + 2 && arguments[baseCount] == "--suspension-evidence"
    guard arguments.count == baseCount || hasEvidence else {
        throw RecoveryTimingReportError.invalidArguments
    }

    let suspensionEvidence: RecoverySuspensionEvidence?
    if hasEvidence,
       let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[baseCount + 1])) {
        suspensionEvidence = try? JSONDecoder().decode(RecoverySuspensionEvidence.self, from: data)
    } else {
        suspensionEvidence = nil
    }
    let timing: RecoveryTiming
    if hasClockContext {
        let samples = try arguments[1..<5].map { path in
            try JSONDecoder().decode(RecoveryClockSample.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        timing = try RecoveryTiming(clockContext: RecoveryTimingClockContext(
            faultBefore: samples[0], faultAfter: samples[1], notification: samples[2], restored: samples[3]
        ), suspensionEvidence: suspensionEvidence)
    } else {
        let values = arguments.prefix(4).compactMap { UInt64($0) }
        guard values.count == 4 else { throw RecoveryTimingReportError.invalidArguments }
        timing = try RecoveryTiming(faultAt: values[0], latestFaultAt: values[1], notificationAt: values[2], restoredAt: values[3])
    }
    let conclusion: String
    switch timing.assessment {
    case .withinDeadline: conclusion = "故障至核验观测上界满足10秒"
    case .exceeded: conclusion = "故障至核验观测下界已超过10秒"
    case .inconclusive: conclusion = "核验观测耗时区间跨越10秒，证据不足"
    }

    let evidenceHeader = hasClockContext
        ? "端点使用采集时的同启动会话系统时钟样本；只根据配对时钟与电源事件推导可证明休眠下界，不验证人工输入的故障或恢复声明，不证明真实硬件恢复，不授权停用。"
        : "仅检查给定时间戳；不核实故障、通知归属、实际恢复或时钟来源，不授权停用。不证明真实硬件恢复。"
    let sleepReport: String
    if let bounds = timing.suspensionBounds {
        let awakeConclusion: String
        switch timing.awakeAssessment {
        case .withinDeadline: awakeConclusion = "清醒耗时上界满足10秒"
        case .exceeded: awakeConclusion = "清醒耗时下界已超过10秒"
        case .inconclusive: awakeConclusion = "清醒耗时区间跨越10秒，证据不足"
        }
        sleepReport = """
        休眠证据=已核验；休眠时长区间=[\(bounds.lowerBoundNanoseconds), \(bounds.upperBoundNanoseconds)] ns
        清醒恢复耗时区间=[\(timing.minimumAwakeElapsedNanoseconds), \(timing.awakeElapsedNanoseconds)] ns；\(awakeConclusion)
        """
    } else if hasEvidence {
        sleepReport = hasClockContext
            ? "休眠证据=不可用或无法定位；未从连续耗时中扣除。"
            : "缺少端点时钟上下文；未从连续耗时中扣除。"
    } else {
        sleepReport = ""
    }

    let report = """
    \(evidenceHeader)
    核验观测可能晚于实际恢复；观测超时不能证明实际恢复超时。
    故障区间=[\(timing.faultAt), \(timing.latestFaultAt)] ns；测量不确定区间宽度=\(timing.uncertaintyNanoseconds) ns
    通知观测=\(timing.notificationAt) ns；恢复核验观测=\(timing.restoredAt) ns
    故障至核验观测耗时=[\(timing.minimumElapsedNanoseconds), \(timing.elapsedNanoseconds)] ns；\(conclusion)
    """
    return sleepReport.isEmpty ? report : report + "\n" + sleepReport
}

func captureRecoveryClock(to path: String) throws {
    let sample = try RecoveryClockSample.capture(bootSession: currentBootSession())
    try writeRecoveryClockSample(sample, to: path)
}

func writeRecoveryClockSample(_ sample: RecoveryClockSample, to path: String) throws {
    try writePrivateRecoveryData(JSONEncoder().encode(sample), to: path)
}

func writeRecoverySuspensionEvidence(_ evidence: RecoverySuspensionEvidence, to path: String) throws {
    try writePrivateRecoveryData(JSONEncoder().encode(evidence), to: path)
}

private func writePrivateRecoveryData(_ data: Data, to path: String) throws {
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    let parent = destination.deletingLastPathComponent()
    let name = destination.lastPathComponent
    guard destination.path.hasPrefix("/"), !name.isEmpty, name != ".", name != ".." else {
        throw RecoveryClockCaptureError.invalidDestination
    }

    if !FileManager.default.fileExists(atPath: parent.path) {
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RecoveryClockCaptureError.insecureDirectory
        }
    }
    let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw RecoveryClockCaptureError.insecureDirectory }
    defer { close(directoryFD) }

    var directoryInfo = stat()
    guard
        fstat(directoryFD, &directoryInfo) == 0,
        directoryInfo.st_uid == getuid(),
        directoryInfo.st_mode & 0o077 == 0,
        directoryInfo.st_mode & (S_IWUSR | S_IXUSR) == (S_IWUSR | S_IXUSR)
    else { throw RecoveryClockCaptureError.insecureDirectory }

    let fileFD = name.withCString {
        openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard fileFD >= 0 else { throw RecoveryClockCaptureError.writeFailed }
    var keepFile = false
    defer {
        if !keepFile { name.withCString { _ = unlinkat(directoryFD, $0, 0) } }
        close(fileFD)
    }
    guard fchmod(fileFD, mode_t(0o600)) == 0 else { throw RecoveryClockCaptureError.writeFailed }

    let wroteAllBytes = data.withUnsafeBytes { bytes -> Bool in
        guard var cursor = bytes.baseAddress else { return data.isEmpty }
        var remaining = bytes.count
        while remaining > 0 {
            let result = Darwin.write(fileFD, cursor, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return false }
            remaining -= result
            cursor = cursor.advanced(by: result)
        }
        return true
    }
    guard wroteAllBytes, fsync(fileFD) == 0 else { throw RecoveryClockCaptureError.writeFailed }
    keepFile = true
}

func currentBootSession() throws -> UUID {
    let name = "kern.bootsessionuuid"
    var length = 0
    guard name.withCString({ sysctlbyname($0, nil, &length, nil, 0) }) == 0, length > 1 else {
        throw RecoveryClockCaptureError.bootSessionUnavailable
    }
    var value = [CChar](repeating: 0, count: length)
    let result = value.withUnsafeMutableBufferPointer { buffer in
        name.withCString { sysctlbyname($0, buffer.baseAddress, &length, nil, 0) }
    }
    guard result == 0, let session = UUID(uuidString: String(cString: value)) else {
        throw RecoveryClockCaptureError.bootSessionUnavailable
    }
    return session
}
