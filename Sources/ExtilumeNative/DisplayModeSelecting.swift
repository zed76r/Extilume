import ExtilumeCore

@MainActor
protocol DisplayModeSelecting: AnyObject {
    var selectedMode: DisplayApplicationMode? { get }
    var availableModes: [DisplayApplicationMode] { get }
    var requiresExplicitActivation: Bool { get }
    var modeDidChange: (@MainActor () -> Void)? { get set }
    func selectMode(_ mode: DisplayApplicationMode)
    func restoreForConfiguration()
}

extension DisplayModeSelecting {
    var availableModes: [DisplayApplicationMode] { [.externalPrimary, .externalOnly] }
}
