import Foundation
import ExtilumeCore

struct ExternalDisplayState: Codable, Equatable {
    let id: UInt32
    let identity: ExternalDisplayIdentity
    let isOnline: Bool
    let isActive: Bool

    var isEnabled: Bool { isOnline && isActive }

    func matches(identity expected: ExternalDisplayIdentity) -> Bool {
        guard id != 0 else { return false }
        do {
            try identity.validate()
            try expected.validate()
            return identity == expected
        } catch {
            return false
        }
    }
}

func matchExternalDisplay(
    identity: ExternalDisplayIdentity,
    numericIDHint: UInt32,
    candidates: [UInt32],
    currentBootSession: UUID,
    read: (UInt32) throws -> ExternalDisplayState?
) throws -> ExternalDisplayState {
    do { try identity.validate() }
    catch { throw RecoveryError.identityConflict }
    guard numericIDHint != 0,
          candidates.allSatisfy({ $0 != 0 }),
          identity.bootSession == currentBootSession else {
        throw RecoveryError.identityConflict
    }

    var seen = Set<UInt32>()
    let candidateIDs = (candidates + [numericIDHint]).filter { seen.insert($0).inserted }
    var states: [ExternalDisplayState] = []
    for candidate in candidateIDs {
        guard let state = try read(candidate) else { continue }
        guard state.id == candidate else { throw RecoveryError.identityConflict }
        states.append(state)
    }

    let matches = states.filter { $0.identity.uuid == identity.uuid }
    guard matches.count == 1, let match = matches.first,
          match.identity == identity,
          !states.contains(where: {
              $0.identity.uuid != identity.uuid
                  && ($0.identity.registryPath == identity.registryPath
                      || $0.identity.registryEntryID == identity.registryEntryID)
          }) else {
        throw RecoveryError.identityConflict
    }
    return match
}
