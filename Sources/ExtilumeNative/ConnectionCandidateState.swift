enum ExternalConnectionService: String, CaseIterable {
    case device = "DCPAVDeviceProxy"
    case service = "DCPAVServiceProxy"
    case videoInterface = "DCPAVVideoInterfaceProxy"
}

struct ConnectionCandidateState {
    private(set) var invalidated = false
    private var services: [UInt64: ExternalConnectionService] = [:]

    var hasCandidates: Bool { !services.isEmpty }

    mutating func matched(
        entryID: UInt64,
        service: ExternalConnectionService,
        isExternal: Bool
    ) -> Bool {
        guard entryID > 0, isExternal, services[entryID] == nil else { return false }
        services[entryID] = service
        return true
    }

    mutating func invalidate(
        entryID: UInt64,
        terminated: Bool
    ) -> ExternalConnectionService? {
        // 无法分类的负向事件也撤权；后续匹配不能证明连接已恢复。
        invalidated = true
        guard let service = services[entryID] else { return nil }
        if terminated { services.removeValue(forKey: entryID) }
        return service
    }
}
