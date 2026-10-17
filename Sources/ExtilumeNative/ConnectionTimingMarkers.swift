import Foundation

enum ConnectionTimingAction: String, CaseIterable, Encodable {
    case armUnplug = "unplug-armed"
    case confirmUnplug = "unplug-confirmed"
    case armReconnect = "reconnect-armed"
    case confirmReconnect = "reconnect-confirmed"
}

private struct ConnectionTimingMarker: Encodable {
    let type = "manual-connection-marker"
    let clock = "mach_continuous_time/ns"
    let action: ConnectionTimingAction
    let continuousNs: UInt64
}

enum ConnectionTimingMarkerError: Error { case invalidSequence }

struct ConnectionTimingMarkers {
    private(set) var count = 0
    private var previousTimestamp: UInt64?

    var isComplete: Bool { count == ConnectionTimingAction.allCases.count }

    mutating func record(_ action: ConnectionTimingAction, at timestamp: UInt64) throws -> String {
        guard !isComplete, action == ConnectionTimingAction.allCases[count],
              previousTimestamp.map({ timestamp >= $0 }) ?? true else {
            throw ConnectionTimingMarkerError.invalidSequence
        }
        let data = try JSONEncoder().encode(ConnectionTimingMarker(action: action, continuousNs: timestamp))
        let line = String(decoding: data, as: UTF8.self)
        previousTimestamp = timestamp
        count += 1
        return line
    }
}
