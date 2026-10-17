import ExtilumeCore
import Foundation

struct InternalDisplayState: Codable, Equatable {
    let id: UInt32
    var identityUUID: UUID
    let isBuiltIn: Bool
    let isOnline: Bool
    let isActive: Bool
    let hardwareIdentity: InternalDisplayHardwareIdentity?
    let reportedIdentityUUID: UUID?

    init(id: UInt32, identityUUID: UUID, isBuiltIn: Bool, isOnline: Bool, isActive: Bool,
         hardwareIdentity: InternalDisplayHardwareIdentity? = nil, reportedIdentityUUID: UUID? = nil) {
        self.id = id
        self.identityUUID = identityUUID
        self.isBuiltIn = isBuiltIn
        self.isOnline = isOnline
        self.isActive = isActive
        self.hardwareIdentity = hardwareIdentity
        self.reportedIdentityUUID = reportedIdentityUUID
    }

    var isEnabled: Bool { isOnline && isActive }

    func matches(identity: UUID, hardwareIdentity expectedHardware: InternalDisplayHardwareIdentity? = nil) -> Bool {
        id != 0 && isBuiltIn && identityUUID == identity
            && (expectedHardware == nil || (hardwareIdentity == expectedHardware && reportedIdentityUUID != nil))
    }
}

func matchInternalDisplay(
    identity: UUID,
    hardwareIdentity expectedHardware: InternalDisplayHardwareIdentity? = nil,
    candidates: [UInt32],
    read: (UInt32) throws -> InternalDisplayState?
) throws -> InternalDisplayState {
    guard candidates.allSatisfy({ $0 != 0 }) else { throw RecoveryError.identityConflict }

    var seen = Set<UInt32>()
    var states: [InternalDisplayState] = []
    for candidate in candidates where seen.insert(candidate).inserted {
        guard let state = try read(candidate) else { continue }
        guard state.id == candidate else { throw RecoveryError.identityConflict }
        states.append(state)
    }

    let matches = states.filter {
        $0.identityUUID == identity || (expectedHardware != nil && $0.hardwareIdentity == expectedHardware)
    }
    guard matches.count == 1, var match = matches.first else { throw RecoveryError.identityConflict }
    let reported = match.reportedIdentityUUID ?? match.identityUUID
    guard states.filter({ ($0.reportedIdentityUUID ?? $0.identityUUID) == reported }).count == 1 else {
        throw RecoveryError.identityConflict
    }
    if let expectedHardware, match.hardwareIdentity == expectedHardware { match.identityUUID = identity }
    guard match.matches(identity: identity, hardwareIdentity: expectedHardware) else { throw RecoveryError.identityConflict }
    return match
}
