struct InternalLinkReconfiguration {
    enum Phase { case idle, prepared, collecting, verifying, failed }

    private(set) var phase: Phase = .idle
    private(set) var firstPendingAt: UInt64?

    private var candidates: [UInt64: ExternalConnectionService] = [:]
    private var videoProgress: [UInt64: Int] = [:]
    private var audioProgress: [UInt64: Int] = [:]
    private var lastVideoAt: [UInt64: UInt64] = [:]
    private var videoStoppedAt: [UInt64: UInt64] = [:]
    private var lastAudioAt: [UInt64: UInt64] = [:]
    private var lastEventAt: UInt64?
    private var beganAt: UInt64?
    private var sawMedia = false

    private static let videoMessages: [UInt32] = [0xe0115004, 0xe0115005, 0xe0115000, 0xe0115001]
    private static let window: UInt64 = 10_000_000_000

    var isPending: Bool {
        (phase == .collecting || phase == .verifying) && firstPendingAt != nil
    }

    @discardableResult
    mutating func prepare(candidates: [UInt64: ExternalConnectionService]) -> Bool {
        guard phase == .idle,
              candidates.count == 3,
              !candidates.keys.contains(0),
              Set(candidates.values) == Set(ExternalConnectionService.allCases) else {
            _ = fail()
            return false
        }
        self.candidates = candidates
        videoProgress = Dictionary(uniqueKeysWithValues: candidates.keys.map { ($0, 0) })
        audioProgress = videoProgress
        lastVideoAt.removeAll(keepingCapacity: true)
        videoStoppedAt.removeAll(keepingCapacity: true)
        lastAudioAt.removeAll(keepingCapacity: true)
        sawMedia = false
        firstPendingAt = nil
        phase = .prepared
        return true
    }

    @discardableResult
    mutating func begin(at: UInt64) -> Bool {
        guard phase == .prepared else { _ = fail(); return false }
        beganAt = at
        lastEventAt = at
        phase = .collecting
        return true
    }

    @discardableResult
    mutating func consume(entryID: UInt64, messageType: UInt32, argument: ConnectionObservedArgument, at: UInt64) -> Bool {
        guard phase == .collecting, let beganAt, let lastEventAt,
              at >= beganAt, at >= lastEventAt else {
            _ = fail()
            return false
        }
        guard messageType != 0xe0115006 else { return false }
        guard candidates[entryID] != nil else {
            _ = fail()
            return false
        }
        guard let messageIndex = Self.videoMessages.firstIndex(of: messageType) else {
            _ = fail()
            return false
        }

        let isVideo: Bool
        switch argument {
        case .one: isVideo = true
        case .zero: isVideo = false
        case .two, .other:
            _ = fail()
            return false
        }
        if let firstPendingAt, at - firstPendingAt >= Self.window {
            _ = fail()
            return false
        }

        if isVideo {
            let progress = videoProgress[entryID, default: 0]
            guard messageIndex == progress,
                  lastVideoAt[entryID].map({ at > $0 }) ?? true else {
                _ = fail()
                return false
            }
            videoProgress[entryID] = progress + 1
            lastVideoAt[entryID] = at
            if messageIndex == 0 { firstPendingAt = firstPendingAt ?? at }
            if messageIndex == 1 { videoStoppedAt[entryID] = at }
        } else {
            let progress = audioProgress[entryID, default: 0]
            guard videoProgress[entryID, default: 0] >= 2,
                  let stoppedAt = videoStoppedAt[entryID], at > stoppedAt,
                  messageIndex == progress, progress < Self.videoMessages.count,
                  at > lastAudioAt[entryID, default: 0] else {
                _ = fail()
                return false
            }
            audioProgress[entryID] = progress + 1
            lastAudioAt[entryID] = at
        }

        sawMedia = true
        self.lastEventAt = at
        return true
    }

    @discardableResult
    mutating func endNative(succeeded: Bool, at: UInt64) -> Bool {
        guard phase == .collecting, let lastEventAt, at >= lastEventAt,
              succeeded else {
            _ = fail()
            return false
        }
        if let firstPendingAt, at - firstPendingAt >= Self.window {
            _ = fail()
            return false
        }
        if sawMedia && videoProgress.values.contains(where: { $0 != Self.videoMessages.count }) {
            _ = fail()
            return false
        }
        self.lastEventAt = at
        phase = .verifying
        return true
    }

    @discardableResult
    mutating func verify(at: UInt64) -> Bool {
        guard phase == .verifying, let lastEventAt, at >= lastEventAt else {
            _ = fail()
            return false
        }
        if let firstPendingAt, at - firstPendingAt >= Self.window {
            _ = fail()
            return false
        }
        phase = .idle
        firstPendingAt = nil
        candidates.removeAll(keepingCapacity: true)
        videoProgress.removeAll(keepingCapacity: true)
        audioProgress.removeAll(keepingCapacity: true)
        lastVideoAt.removeAll(keepingCapacity: true)
        videoStoppedAt.removeAll(keepingCapacity: true)
        lastAudioAt.removeAll(keepingCapacity: true)
        self.lastEventAt = nil
        beganAt = nil
        sawMedia = false
        return true
    }

    @discardableResult
    mutating func fail() -> UInt64? {
        phase = .failed
        return firstPendingAt
    }
}
