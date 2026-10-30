import ExtilumeCore
import Foundation

@MainActor
protocol DisplayModePreferenceStoring {
    var selectedMode: DisplayApplicationMode? { get }
    var internalControlLocked: Bool { get }
    var externalHandoffRequested: Bool { get }
    func select(_ mode: DisplayApplicationMode) throws
    func lockInternalControl() throws
    func setExternalHandoffRequested(_ requested: Bool) throws
}

@MainActor
final class DisplayModePreferences: DisplayModePreferenceStoring {
    private let defaults: UserDefaults
    private let protectionDefaults: UserDefaults?
    private let modeKey = "explicitDisplayMode.v1"
    private let lockKey = "internalControlFailure.v1"
    private let externalHandoffKey = "externalHandoffRequested.v1"

    init(defaults: UserDefaults = .standard, protectionDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.protectionDefaults = protectionDefaults
    }

    var selectedMode: DisplayApplicationMode? {
        defaults.string(forKey: modeKey).flatMap(DisplayApplicationMode.init(rawValue:))
    }

    // Any persisted failure value, including malformed data, keeps the gate closed.
    var internalControlLocked: Bool {
        defaults.object(forKey: lockKey) != nil || protectionDefaults?.object(forKey: lockKey) != nil
    }
    var externalHandoffRequested: Bool { defaults.bool(forKey: externalHandoffKey) }

    func select(_ mode: DisplayApplicationMode) throws {
        defaults.set(mode.rawValue, forKey: modeKey)
        guard defaults.synchronize() else { throw RecoveryStoreError.ioFailure }
    }

    func lockInternalControl() throws {
        defaults.set(true, forKey: lockKey)
        protectionDefaults?.set(true, forKey: lockKey)
        let localSaved = defaults.synchronize()
        let protectionSaved = protectionDefaults?.synchronize() ?? true
        guard localSaved && protectionSaved else { throw RecoveryStoreError.ioFailure }
    }

    func setExternalHandoffRequested(_ requested: Bool) throws {
        defaults.set(requested, forKey: externalHandoffKey)
        guard defaults.synchronize() else { throw RecoveryStoreError.ioFailure }
    }
}
