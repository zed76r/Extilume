enum ExternalConnectionService: String, CaseIterable {
    case device = "DCPAVDeviceProxy"
    case service = "DCPAVServiceProxy"
    case videoInterface = "DCPAVVideoInterfaceProxy"
}

struct ConnectionCandidateState {
    private(set) var invalidated = false
    private var services: [UInt64: ExternalConnectionService] = [:]

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
        guard let service = services[entryID] else { return nil }
        // 重新匹配不能证明连接已恢复，因此失效标记不会自动清除。
        invalidated = true
        if terminated { services.removeValue(forKey: entryID) }
        return service
    }
}
