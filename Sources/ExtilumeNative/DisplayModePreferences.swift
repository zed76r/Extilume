import ExtilumeCore
import Foundation

@MainActor
protocol DisplayModePreferenceStoring {
    var selectedMode: DisplayApplicationMode? { get }
    var internalControlLocked: Bool { get }
    func select(_ mode: DisplayApplicationMode) throws
    func lockInternalControl() throws
}

@MainActor
final class DisplayModePreferences: DisplayModePreferenceStoring {
    private let defaults: UserDefaults
    private let modeKey = "explicitDisplayMode.v1"
    private let lockKey = "internalControlFailure.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var selectedMode: DisplayApplicationMode? {
        defaults.string(forKey: modeKey).flatMap(DisplayApplicationMode.init(rawValue:))
    }

    // Any persisted failure value, including malformed data, keeps the gate closed.
    var internalControlLocked: Bool { defaults.object(forKey: lockKey) != nil }

    func select(_ mode: DisplayApplicationMode) throws {
        defaults.set(mode.rawValue, forKey: modeKey)
        guard defaults.synchronize() else { throw RecoveryStoreError.ioFailure }
    }

    func lockInternalControl() throws {
        defaults.set(true, forKey: lockKey)
        guard defaults.synchronize() else { throw RecoveryStoreError.ioFailure }
    }
}
