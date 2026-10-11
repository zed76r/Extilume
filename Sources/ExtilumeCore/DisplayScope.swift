import Foundation

public enum DisplayIdentity: Equatable, Codable {
    case builtIn
    case physical
    case virtual
    case unknown
}

public struct DisplayRegistryEvidence: Equatable {
    public let downstream: String?
    public let registryPath: String?
    public let edidUUID: String?

    public init(downstream: String?, registryPath: String?, edidUUID: String?) {
        self.downstream = downstream
        self.registryPath = registryPath
        self.edidUUID = edidUUID
    }
}

public func matchPhysicalHDMIDisplayUUID(
    location: String?,
    displayUUID: String?,
    candidates: [DisplayRegistryEvidence]
) -> UUID? {
    guard let location, !location.isEmpty,
          let displayUUID, !displayUUID.isEmpty,
          let parsedUUID = UUID(uuidString: displayUUID) else { return nil }
    guard !candidates.contains(where: {
        $0.downstream == "HDMI" && ($0.registryPath?.isEmpty ?? true)
    }) else { return nil }

    let pathMatches = candidates.filter { $0.registryPath == location }
    guard pathMatches.count == 1,
          let candidate = pathMatches.first,
          candidate.downstream == "HDMI",
          let edidUUID = candidate.edidUUID,
          !edidUUID.isEmpty else { return nil }

    return parsedUUID
}

public struct DisplayObservation: Equatable {
    public let identity: DisplayIdentity
    public let isOnline: Bool
    public let isActive: Bool
    public let isMirrored: Bool

    public init(identity: DisplayIdentity, isOnline: Bool, isActive: Bool, isMirrored: Bool) {
        self.identity = identity
        self.isOnline = isOnline
        self.isActive = isActive
        self.isMirrored = isMirrored
    }
}

public enum ScopeIssue: Equatable {
    case noDisplay
    case noExternalDisplay
    case multipleExternalDisplays
    case virtualExternalDisplay
    case unknownExternalIdentity
    case externalNotOnline
    case externalNotActive
    case mirrored
}

public struct ScopeAssessment: Equatable {
    public let issues: [ScopeIssue]

    public var isSupported: Bool { issues.isEmpty }
}

public func assessScope(_ displays: [DisplayObservation]) -> ScopeAssessment {
    guard !displays.isEmpty else { return ScopeAssessment(issues: [.noDisplay]) }

    var issues: [ScopeIssue] = []
    if displays.contains(where: \.isMirrored) { issues.append(.mirrored) }

    let externalDisplays = displays.filter { $0.identity != .builtIn }
    switch externalDisplays.count {
    case 0:
        issues.append(.noExternalDisplay)
    case 1:
        let external = externalDisplays[0]
        switch external.identity {
        case .physical:
            if !external.isOnline { issues.append(.externalNotOnline) }
            if !external.isActive { issues.append(.externalNotActive) }
        case .virtual:
            issues.append(.virtualExternalDisplay)
        case .unknown:
            issues.append(.unknownExternalIdentity)
        case .builtIn:
            break
        }
    default:
        issues.append(.multipleExternalDisplays)
    }

    return ScopeAssessment(issues: issues)
}
