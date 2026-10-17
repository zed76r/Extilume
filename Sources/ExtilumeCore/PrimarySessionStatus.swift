public enum PrimarySessionStatus: Sendable, Equatable {
    case waiting
    case unsupported(String)
    case applying
    case applied
    case manualConfiguration
    case applicationFailedRestored
    case recoveryIncomplete
    case unconfirmed
    case confirmationFailed
    case restoringAndQuitting
    case quitFailed
    case quitWaitingForDisplays

    public var text: String {
        switch self {
        case .waiting: "等待外屏连接"
        case .unsupported(let reason): "暂不支持：\(reason)"
        case .applying: "正在应用外屏主屏…"
        case .applied: "外屏主屏已生效"
        case .manualConfiguration: "当前使用手动配置"
        case .applicationFailedRestored: "应用失败，已恢复"
        case .recoveryIncomplete: "恢复未完成"
        case .unconfirmed: "无法确认显示状态"
        case .confirmationFailed: "未能保留当前配置"
        case .restoringAndQuitting: "正在恢复并退出…"
        case .quitFailed: "恢复失败，尚未退出"
        case .quitWaitingForDisplays: "显示器未齐，等待恢复退出"
        }
    }

    public var canRetryApplication: Bool { self == .applicationFailedRestored }

    public var canRetryRecovery: Bool {
        switch self {
        case .recoveryIncomplete, .unconfirmed, .confirmationFailed, .quitFailed, .quitWaitingForDisplays: true
        default: false
        }
    }

    public var needsRecovery: Bool { canRetryRecovery }

    public var canConfirmConfiguration: Bool {
        switch self {
        case .unconfirmed, .confirmationFailed, .quitFailed: true
        default: false
        }
    }

    public var canQuit: Bool {
        switch self {
        case .recoveryIncomplete, .unconfirmed, .confirmationFailed, .restoringAndQuitting, .quitFailed, .quitWaitingForDisplays: false
        default: true
        }
    }
}
