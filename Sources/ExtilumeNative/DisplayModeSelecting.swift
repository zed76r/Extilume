import ExtilumeCore

@MainActor
protocol DisplayModeSelecting: AnyObject {
    var selectedMode: DisplayApplicationMode? { get }
    var requiresExplicitActivation: Bool { get }
    var modeDidChange: (@MainActor () -> Void)? { get set }
    func selectMode(_ mode: DisplayApplicationMode)
    func restoreForConfiguration()
}
