enum ExternalConnectionService: String, CaseIterable, Encodable, Sendable {
    case device = "DCPAVDeviceProxy"
    case service = "DCPAVServiceProxy"
    case videoInterface = "DCPAVVideoInterfaceProxy"
}

enum ConnectionCandidateRole: String, Encodable, Sendable {
    case unidentified
    case unregistered
    case registeredExternal
    case registeredEmbedded
    case retiredEmbedded
}

struct ConnectionCandidateDiagnostic: Encodable, Equatable, Sendable {
    let role: ConnectionCandidateRole
    let service: ExternalConnectionService?
}

struct ConnectionCandidateState {
    private(set) var invalidated = false
    private var services: [UInt64: ExternalConnectionService] = [:]
    private var embeddedServices: [UInt64: ExternalConnectionService] = [:]
    private var retiredEmbedded: Set<UInt64> = []

    var hasCandidates: Bool { !services.isEmpty }

    func reconfigurationCandidates(registered: Set<UInt64>, internalDisplayID: UInt32?) -> [UInt64: ExternalConnectionService]? {
        guard let internalDisplayID, internalDisplayID != 0, !invalidated,
              services.count == ExternalConnectionService.allCases.count,
              Set(services.values) == Set(ExternalConnectionService.allCases),
              Set(services.keys).isSubset(of: registered) else { return nil }
        return services
    }

    func permitsProtectionInformation(
        entryID: UInt64, messageType: UInt32, messageArgument: ConnectionObservedArgument,
        interestRegistered: Bool, internalDisplayID: UInt32?
    ) -> Bool {
        guard let internalDisplayID, internalDisplayID != 0, interestRegistered,
              !invalidated, entryID != 0, services[entryID] != nil,
              messageType == 0xe0115006 else { return false }
        switch messageArgument {
        case .zero, .one, .two: return true
        case .other: return false
        }
    }

    func diagnosticCandidate(entryID: UInt64) -> ConnectionCandidateDiagnostic {
        guard entryID > 0 else {
            return ConnectionCandidateDiagnostic(role: .unidentified, service: nil)
        }
        if retiredEmbedded.contains(entryID) {
            return ConnectionCandidateDiagnostic(role: .retiredEmbedded, service: embeddedServices[entryID])
        }
        if let service = services[entryID] {
            return ConnectionCandidateDiagnostic(role: .registeredExternal, service: service)
        }
        if let service = embeddedServices[entryID] {
            return ConnectionCandidateDiagnostic(role: .registeredEmbedded, service: service)
        }
        return ConnectionCandidateDiagnostic(role: .unregistered, service: nil)
    }

    mutating func matched(
        entryID: UInt64,
        service: ExternalConnectionService,
        location: String?
    ) -> Bool {
        guard entryID > 0 else { return false }
        if let known = embeddedServices[entryID] {
            if location != "Embedded" || service != known {
                embeddedServices.removeValue(forKey: entryID)
                retiredEmbedded.insert(entryID)
                invalidated = true
            }
            return false
        }
        if let known = services[entryID] {
            if location != "External" || service != known { invalidated = true }
            return false
        }
        guard !retiredEmbedded.contains(entryID) else { return false }
        switch location {
        case "External": services[entryID] = service
        case "Embedded": embeddedServices[entryID] = service
        default: return false
        }
        return true
    }

    func isKnownEmbedded(entryID: UInt64) -> Bool {
        embeddedServices[entryID] != nil
    }

    mutating func consumeEmbeddedTermination(entryID: UInt64, service: ExternalConnectionService, location: String?) -> Bool {
        guard !invalidated, entryID > 0, !retiredEmbedded.contains(entryID),
              location == "Embedded", embeddedServices[entryID] == service else { return false }
        // 保留角色以拒绝迟到 matched 的冲突；退役 ID 不得重新获得终止额度。
        retiredEmbedded.insert(entryID)
        return true
    }

    mutating func invalidate(
        entryID: UInt64,
        terminated: Bool
    ) -> ExternalConnectionService? {
        // 无法分类的负向事件也撤权；后续匹配不能证明连接已恢复。
        invalidated = true
        if embeddedServices.removeValue(forKey: entryID) != nil { retiredEmbedded.insert(entryID) }
        guard let service = services[entryID] else { return nil }
        if terminated { services.removeValue(forKey: entryID) }
        return service
    }
}
