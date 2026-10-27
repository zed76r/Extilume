import CoreGraphics
import ExtilumeCore
import Foundation
import IOKit

private let zeroRecoveryUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

enum ExternalRecoveryObservation: Codable, Equatable, Sendable {
    case identified(ExternalDisplayState)
    case connection(ExternalConnectionEvidence)

    func matches(identity: ExternalDisplayIdentity, numericIDHint: UInt32) -> Bool {
        switch self {
        case .identified(let state): return state.matches(identity: identity)
        case .connection(let evidence): return evidence.matches(identity: identity, numericIDHint: numericIDHint)
        }
    }
}

struct ExternalConnectionEvidence: Codable, Equatable, Sendable {
    let id: UInt32
    let observedUUID: UUID
    let registryPath: String
    let edidUUID: String
    let bootSession: UUID
    let registryEntryID: UInt64
    let isBuiltin: Bool
    let isOnline: Bool
    let isActive: Bool
    let matchingSlotCount: Int
    let allSlotsExcludeOriginalUUID: Bool
    let registryIsHDMI: Bool
    let registryClassMatches: Bool

    var isDisabled: Bool { !isOnline && !isActive }

    func matches(identity: ExternalDisplayIdentity, numericIDHint: UInt32) -> Bool {
        guard (try? identity.validate()) != nil else { return false }
        return id != 0 && id == numericIDHint && observedUUID == zeroRecoveryUUID && !isBuiltin
            && registryPath == identity.registryPath && edidUUID == identity.edidUUID
            && bootSession == identity.bootSession && registryEntryID == identity.registryEntryID
            && matchingSlotCount == 1 && allSlotsExcludeOriginalUUID && registryIsHDMI && registryClassMatches
    }
}

struct ExternalRecoverySlot {
    let id: UInt32
    let reportedID: UInt32?
    let uuid: UUID?
    let location: String?
}

func matchingExternalRecoverySlot(
    _ slots: [ExternalRecoverySlot], identity: ExternalDisplayIdentity, numericIDHint: UInt32
) -> (uuid: UUID, matchingSlotCount: Int)? {
    guard numericIDHint != 0, Set(slots.map(\.id)).count == slots.count,
          slots.allSatisfy({ $0.id != 0 && $0.reportedID == $0.id && $0.uuid != nil && $0.uuid != identity.uuid }) else {
        return nil
    }
    // 不活跃幽灵槽可能没有位置；只有原路径唯一匹配的槽能成为恢复目标。
    let matches = slots.filter { $0.location == identity.registryPath }
    guard matches.count == 1, let target = matches.first, target.id == numericIDHint,
          let uuid = target.uuid, uuid == zeroRecoveryUUID else { return nil }
    return (uuid, matches.count)
}

func readExternalRecoveryObservation(
    identity: ExternalDisplayIdentity, numericIDHint: UInt32
) throws -> ExternalRecoveryObservation {
    do {
        return .identified(try readExternalDisplay(identity: identity, numericIDHint: numericIDHint))
    } catch RecoveryError.identityConflict, RecoveryError.invalidRecord {
        // 身份元数据不可用时才尝试连接证据；其他错误不得降级。
    }
    guard (try? identity.validate()) != nil, numericIDHint != 0 else { throw RecoveryError.identityConflict }
    let bootSession = try currentBootSession()
    guard bootSession == identity.bootSession else { throw RecoveryError.identityConflict }
    let list = readPrivateDisplaySlots()
    guard list.apiFound, let ids = list.displayIDs, ids.contains(numericIDHint) else {
        throw RecoveryError.identityConflict
    }
    var slots: [ExternalRecoverySlot] = []
    for id in ids {
        guard let info = coreDisplayRecoveryDiagnosticInfo(id) else { throw RecoveryError.identityConflict }
        let reported = info["kCGDisplayID"] as? NSNumber
        let reportedID = reported.flatMap { $0 == NSNumber(value: id) ? id : nil }
        let uuidText = (info["DisplayUUID"] as? String) ?? (info["kCGDisplayUUID"] as? String)
        slots.append(ExternalRecoverySlot(id: id, reportedID: reportedID,
                                          uuid: uuidText.flatMap(UUID.init(uuidString:)),
                                          location: info["IODisplayLocation"] as? String))
    }
    guard let target = matchingExternalRecoverySlot(slots, identity: identity, numericIDHint: numericIDHint) else {
        throw RecoveryError.identityConflict
    }
    let service = identity.registryPath.withCString { IORegistryEntryFromPath(kIOMainPortDefault, $0) }
    guard service != IO_OBJECT_NULL else { throw RecoveryError.identityConflict }
    defer { IOObjectRelease(service) }
    var entryID: UInt64 = 0
    var path = [CChar](repeating: 0, count: 512)
    guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
          path.withUnsafeMutableBufferPointer({ IORegistryEntryGetPath(service, kIOServicePlane, $0.baseAddress!) }) == KERN_SUCCESS,
          let edid = IORegistryEntryCreateCFProperty(service, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { throw RecoveryError.identityConflict }
    let actualPath = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any]
    let evidence = ExternalConnectionEvidence(
        id: numericIDHint, observedUUID: target.uuid, registryPath: actualPath, edidUUID: edid,
        bootSession: bootSession, registryEntryID: entryID, isBuiltin: CGDisplayIsBuiltin(numericIDHint) != 0,
        isOnline: CGDisplayIsOnline(numericIDHint) != 0, isActive: CGDisplayIsActive(numericIDHint) != 0,
        matchingSlotCount: target.matchingSlotCount, allSlotsExcludeOriginalUUID: true,
        registryIsHDMI: transport?["Downstream"] as? String == "HDMI",
        registryClassMatches: IOObjectConformsTo(service, "IOMobileFramebufferShim") != 0
    )
    guard evidence.matches(identity: identity, numericIDHint: numericIDHint) else { throw RecoveryError.identityConflict }
    return .connection(evidence)
}
