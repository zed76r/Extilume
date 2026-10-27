import ColorSync
import CoreFoundation
import CoreGraphics
import ExtilumeCore
import Foundation
import IOKit

struct ExternalRecoveryPrivateDisplayListSnapshot {
    let apiFound: Bool
    let readSucceeded: Bool
    let count: Int
    let containsHint: Bool
}

struct ExternalRecoveryRegistrySnapshot {
    let serviceFound: Bool
    let classMatches: Bool
    let entryIDMatches: Bool
    let pathMatches: Bool
    let isHDMI: Bool
    let edidUUIDPresent: Bool
    let edidUUIDMatches: Bool
    let edidDataPresent: Bool
    let edidByteCount: Int
}

struct ExternalRecoveryDiagnosticSnapshot {
    let currentBootSession: UUID?
    let numericHintIsBuiltin: Bool
    let numericHintIsOnline: Bool
    let numericHintIsActive: Bool
    let coreDisplayInfo: [String: Any]?
    let colorSyncUUID: UUID?
    let colorSyncReverseDisplayID: UInt32
    let privateDisplayList: ExternalRecoveryPrivateDisplayListSnapshot
    let registry: ExternalRecoveryRegistrySnapshot
}

private struct ExternalRecoveryDiagnosticReport: Encodable {
    let diagnosticOnly = true
    let currentBootAvailable: Bool
    let currentBootMatches: Bool
    let numericHintIsBuiltin: Bool
    let numericHintIsOnline: Bool
    let numericHintIsActive: Bool
    let coreDisplayInfoAvailable: Bool
    let coreDisplayReportedIDMatches: Bool
    let coreDisplayUUIDPresent: Bool
    let coreDisplayUUIDIsZero: Bool
    let coreDisplayUUIDMatches: Bool
    let coreDisplayRegistryLocationMatches: Bool
    let colorSyncUUIDPresent: Bool
    let colorSyncUUIDIsZero: Bool
    let colorSyncUUIDMatches: Bool
    let colorSyncReverseDisplayIDAvailable: Bool
    let colorSyncReverseDisplayIDMatchesHint: Bool
    let privateDisplayListAPIFound: Bool
    let privateDisplayListReadSucceeded: Bool
    let privateDisplayListCount: Int
    let privateDisplayListContainsHint: Bool
    let registryServiceFound: Bool
    let registryClassMatches: Bool
    let registryEntryIDMatches: Bool
    let registryPathMatches: Bool
    let registryTransportIsHDMI: Bool
    let registryEDIDUUIDPresent: Bool
    let registryEDIDUUIDMatches: Bool
    let registryEDIDDataPresent: Bool
    let registryEDIDByteCount: Int
}

private let zeroExternalRecoveryUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

func externalRecoveryDiagnosticReport(for record: RecoveryRecord) throws -> String {
    let responsibility = try validatedExternalRecoveryResponsibility(in: record)
    let snapshot = collectExternalRecoveryDiagnosticSnapshot(for: responsibility)
    return try encodeExternalRecoveryDiagnosticReport(for: responsibility, snapshot: snapshot)
}

func makeExternalRecoveryDiagnosticReport(
    for record: RecoveryRecord,
    snapshot: ExternalRecoveryDiagnosticSnapshot
) throws -> String {
    let responsibility = try validatedExternalRecoveryResponsibility(in: record)
    return try encodeExternalRecoveryDiagnosticReport(for: responsibility, snapshot: snapshot)
}

private func validatedExternalRecoveryResponsibility(
    in record: RecoveryRecord
) throws -> ExternalDisplayResponsibility {
    do { try record.validate() }
    catch { throw RecoveryError.invalidRecord }
    guard record.version == 4,
          record.internalDisplay == nil,
          let responsibility = record.externalDisplay,
          responsibility.numericIDHint != 0 else {
        throw RecoveryError.invalidRecord
    }
    return responsibility
}

private func encodeExternalRecoveryDiagnosticReport(
    for responsibility: ExternalDisplayResponsibility,
    snapshot: ExternalRecoveryDiagnosticSnapshot
) throws -> String {
    let hint = responsibility.numericIDHint
    let identity = responsibility.identity
    let coreDisplayUUIDText = (snapshot.coreDisplayInfo?["DisplayUUID"] as? String)
        ?? (snapshot.coreDisplayInfo?["kCGDisplayUUID"] as? String)
    let coreDisplayUUID = coreDisplayUUIDText.flatMap(UUID.init(uuidString:))
    let reverseIDAvailable = snapshot.colorSyncReverseDisplayID != 0
    let diagnostic = ExternalRecoveryDiagnosticReport(
        currentBootAvailable: snapshot.currentBootSession != nil,
        currentBootMatches: snapshot.currentBootSession == identity.bootSession,
        numericHintIsBuiltin: snapshot.numericHintIsBuiltin,
        numericHintIsOnline: snapshot.numericHintIsOnline,
        numericHintIsActive: snapshot.numericHintIsActive,
        coreDisplayInfoAvailable: snapshot.coreDisplayInfo != nil,
        coreDisplayReportedIDMatches: (snapshot.coreDisplayInfo?["kCGDisplayID"] as? NSNumber)?.uint32Value == hint,
        coreDisplayUUIDPresent: coreDisplayUUIDText != nil,
        coreDisplayUUIDIsZero: coreDisplayUUID == zeroExternalRecoveryUUID,
        coreDisplayUUIDMatches: coreDisplayUUID == identity.uuid,
        coreDisplayRegistryLocationMatches: (snapshot.coreDisplayInfo?["IODisplayLocation"] as? String) == identity.registryPath,
        colorSyncUUIDPresent: snapshot.colorSyncUUID != nil,
        colorSyncUUIDIsZero: snapshot.colorSyncUUID == zeroExternalRecoveryUUID,
        colorSyncUUIDMatches: snapshot.colorSyncUUID == identity.uuid,
        colorSyncReverseDisplayIDAvailable: reverseIDAvailable,
        colorSyncReverseDisplayIDMatchesHint: reverseIDAvailable && snapshot.colorSyncReverseDisplayID == hint,
        privateDisplayListAPIFound: snapshot.privateDisplayList.apiFound,
        privateDisplayListReadSucceeded: snapshot.privateDisplayList.readSucceeded,
        privateDisplayListCount: snapshot.privateDisplayList.count,
        privateDisplayListContainsHint: snapshot.privateDisplayList.readSucceeded && snapshot.privateDisplayList.containsHint,
        registryServiceFound: snapshot.registry.serviceFound,
        registryClassMatches: snapshot.registry.classMatches,
        registryEntryIDMatches: snapshot.registry.entryIDMatches,
        registryPathMatches: snapshot.registry.pathMatches,
        registryTransportIsHDMI: snapshot.registry.isHDMI,
        registryEDIDUUIDPresent: snapshot.registry.edidUUIDPresent,
        registryEDIDUUIDMatches: snapshot.registry.edidUUIDMatches,
        registryEDIDDataPresent: snapshot.registry.edidDataPresent,
        registryEDIDByteCount: snapshot.registry.edidByteCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(diagnostic), as: UTF8.self)
}

private func collectExternalRecoveryDiagnosticSnapshot(
    for responsibility: ExternalDisplayResponsibility
) -> ExternalRecoveryDiagnosticSnapshot {
    let hint = responsibility.numericIDHint
    let identity = responsibility.identity
    let coreDisplayInfo = coreDisplayRecoveryDiagnosticInfo(hint)
    let createdUUID = CGDisplayCreateUUIDFromDisplayID(hint)?.takeRetainedValue()
    let colorSyncUUID = createdUUID.flatMap { value in
        let text = CFUUIDCreateString(kCFAllocatorDefault, value) as String?
        return text.flatMap(UUID.init(uuidString:))
    }
    let recordedCFUUID = CFUUIDCreateFromString(kCFAllocatorDefault, identity.uuid.uuidString as CFString)
    let reverseDisplayID = recordedCFUUID.map(CGDisplayGetDisplayIDFromUUID) ?? 0

    return ExternalRecoveryDiagnosticSnapshot(
        currentBootSession: try? currentBootSession(),
        numericHintIsBuiltin: CGDisplayIsBuiltin(hint) != 0,
        numericHintIsOnline: CGDisplayIsOnline(hint) != 0,
        numericHintIsActive: CGDisplayIsActive(hint) != 0,
        coreDisplayInfo: coreDisplayInfo,
        colorSyncUUID: colorSyncUUID,
        colorSyncReverseDisplayID: reverseDisplayID,
        privateDisplayList: readPrivateDisplayList(containing: hint),
        registry: readExternalRecoveryRegistrySnapshot(for: identity)
    )
}

private func readPrivateDisplayList(containing hint: UInt32) -> ExternalRecoveryPrivateDisplayListSnapshot {
    let result = readPrivateDisplaySlots()
    return ExternalRecoveryPrivateDisplayListSnapshot(
        apiFound: result.apiFound,
        readSucceeded: result.displayIDs != nil,
        count: result.displayIDs?.count ?? 0,
        containsHint: result.displayIDs?.contains(hint) ?? false
    )
}

private func readExternalRecoveryRegistrySnapshot(
    for identity: ExternalDisplayIdentity
) -> ExternalRecoveryRegistrySnapshot {
    let service = identity.registryPath.withCString {
        IORegistryEntryFromPath(kIOMainPortDefault, $0)
    }
    guard service != IO_OBJECT_NULL else {
        return ExternalRecoveryRegistrySnapshot(
            serviceFound: false, classMatches: false, entryIDMatches: false, pathMatches: false,
            isHDMI: false, edidUUIDPresent: false, edidUUIDMatches: false,
            edidDataPresent: false, edidByteCount: 0
        )
    }
    defer { IOObjectRelease(service) }

    var entryID: UInt64 = 0
    let entryIDMatches = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
        && entryID == identity.registryEntryID
    let pathMatches = registryPathMatches(service, identity.registryPath)
    let transport = registryProperty("Transport", of: service) as? [String: Any]
    let isHDMI = transport?["Downstream"] as? String == "HDMI"
    let edidUUID = registryProperty("EDID UUID", of: service) as? String
    let edidData = registryProperty("IODisplayEDID", of: service) as? Data
    let byteCount = edidData?.count ?? 0

    return ExternalRecoveryRegistrySnapshot(
        serviceFound: true,
        classMatches: IOObjectConformsTo(service, "IOMobileFramebufferShim") != 0,
        entryIDMatches: entryIDMatches,
        pathMatches: pathMatches,
        isHDMI: isHDMI,
        edidUUIDPresent: edidUUID != nil,
        edidUUIDMatches: edidUUID == identity.edidUUID,
        edidDataPresent: edidData != nil,
        edidByteCount: byteCount
    )
}

private func registryProperty(_ key: String, of service: io_registry_entry_t) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

private func registryPathMatches(_ service: io_registry_entry_t, _ expected: String) -> Bool {
    var path = [CChar](repeating: 0, count: 512)
    guard path.withUnsafeMutableBufferPointer({
        IORegistryEntryGetPath(service, kIOServicePlane, $0.baseAddress!)
    }) == KERN_SUCCESS else { return false }
    return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) == expected }
}
