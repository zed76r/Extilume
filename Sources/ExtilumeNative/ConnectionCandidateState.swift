enum ExternalConnectionService: String, CaseIterable {
    case device = "DCPAVDeviceProxy"
    case service = "DCPAVServiceProxy"
    case videoInterface = "DCPAVVideoInterfaceProxy"
}

struct ConnectionCandidateState {
    private(set) var invalidated = false
    private var services: [UInt64: ExternalConnectionService] = [:]
    private var embeddedServices: [UInt64: ExternalConnectionService] = [:]
    private var retiredEmbedded: Set<UInt64> = []

    var hasCandidates: Bool { !services.isEmpty }

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
