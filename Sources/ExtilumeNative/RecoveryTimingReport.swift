import ExtilumeCore

private enum RecoveryTimingReportError: Error { case invalidArguments }

func recoveryTimingReport(arguments: [String]) throws -> String {
    let values = arguments.compactMap { UInt64($0) }
    guard arguments.count == 4, values.count == 4 else { throw RecoveryTimingReportError.invalidArguments }
    let timing = try RecoveryTiming(
        faultAt: values[0], latestFaultAt: values[1], notificationAt: values[2], restoredAt: values[3]
    )
    let conclusion: String
    switch timing.assessment {
    case .withinDeadline: conclusion = "故障至核验观测上界满足10秒"
    case .exceeded: conclusion = "故障至核验观测下界已超过10秒"
    case .inconclusive: conclusion = "核验观测耗时区间跨越10秒，证据不足"
    }
    return """
    仅检查给定时间戳；不核实故障、通知归属、实际恢复或时钟来源，不授权停用。
    核验观测可能晚于实际恢复；观测超时不能证明实际恢复超时。
    故障区间=[\(timing.faultAt), \(timing.latestFaultAt)] ns；测量不确定区间宽度=\(timing.uncertaintyNanoseconds) ns
    通知观测=\(timing.notificationAt) ns；恢复核验观测=\(timing.restoredAt) ns
    故障至核验观测耗时=[\(timing.minimumElapsedNanoseconds), \(timing.elapsedNanoseconds)] ns；\(conclusion)
    """
}
