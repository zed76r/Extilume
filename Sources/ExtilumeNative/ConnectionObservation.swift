import Foundation

enum ConnectionObservationEvent: String, Encodable, Sendable { case matched, interest, terminated, watchFailed }
enum ConnectionObservationDisposition: String, Encodable, Sendable {
    case registered, unchanged, revoked, controlledEmbeddedTermination, informational, pendingReconfiguration
}
enum ConnectionObservedLocation: String, Encodable, Sendable {
    case external, embedded, unavailable, other

    init(_ value: String?) {
        switch value {
        case "External": self = .external
        case "Embedded": self = .embedded
        case nil: self = .unavailable
        default: self = .other
        }
    }
}
enum ConnectionRegistryScope: String, Encodable, Sendable {
    case unknown, target, other
    case expectedInternal = "expected-internal"
    case identityConflict = "identity-conflict"
}

enum ConnectionDisplayScope: String, Encodable, Sendable {
    case unknown, other
    case expectedInternal = "expected-internal"
}

enum ConnectionObservedArgument: String, Encodable, Sendable {
    case zero, one, two, other

    init(_ argument: UnsafeMutableRawPointer?) {
        // The callback may carry scalar data; never dereference or retain its pointer.
        switch UInt(bitPattern: argument) {
        case 0: self = .zero
        case 1: self = .one
        case 2: self = .two
        default: self = .other
        }
    }
}

enum ConnectionMessageClassification: String, Encodable, Equatable, Sendable {
    case protectionChanged
    case audioLinkStart
    case videoLinkStart
    case audioLinkStarted
    case videoLinkStarted
    case audioLinkStop
    case videoLinkStop
    case audioLinkStopped
    case videoLinkStopped
    case unknown
}

// 仅解释已核对的 IOAV 观测；不得据此授予或保留停用授权。
func connectionMessageClassification(
    event: ConnectionObservationEvent,
    candidate: ConnectionCandidateDiagnostic,
    messageType: UInt32?,
    messageArgument: ConnectionObservedArgument?
) -> ConnectionMessageClassification? {
    guard event == .interest else { return nil }
    guard candidate.role == .registeredExternal, candidate.service != nil else { return .unknown }

    switch messageType {
    case 0xe0115006:
        return .protectionChanged
    case 0xe0115000:
        return connectionLinkClassification(messageArgument, audio: .audioLinkStart, video: .videoLinkStart)
    case 0xe0115001:
        return connectionLinkClassification(messageArgument, audio: .audioLinkStarted, video: .videoLinkStarted)
    case 0xe0115004:
        return connectionLinkClassification(messageArgument, audio: .audioLinkStop, video: .videoLinkStop)
    case 0xe0115005:
        return connectionLinkClassification(messageArgument, audio: .audioLinkStopped, video: .videoLinkStopped)
    default:
        return .unknown
    }
}

private func connectionLinkClassification(
    _ argument: ConnectionObservedArgument?,
    audio: ConnectionMessageClassification,
    video: ConnectionMessageClassification
) -> ConnectionMessageClassification {
    switch argument {
    case .zero: return audio
    case .one: return video
    default: return .unknown
    }
}

func connectionRegistryScope(entryID: UInt64, target: UInt64, internalProof: UInt64?) -> ConnectionRegistryScope {
    guard entryID != 0 else { return .unknown }
    if entryID == target { return entryID == internalProof ? .identityConflict : .target }
    return entryID == internalProof ? .expectedInternal : .other
}

struct ConnectionObservation: Encodable, Sendable {
    let type = "connection-observation"
    let clock = "mach_continuous_time/ns"
    let role: InternalLifecycleRole
    let observerStartedAtNanoseconds: UInt64?
    let continuousNs: UInt64
    let event: ConnectionObservationEvent
    let candidateOrdinal: UInt64?
    let candidate: ConnectionCandidateDiagnostic
    let registryScope: ConnectionRegistryScope
    let messageType: UInt32?
    let messageArgument: ConnectionObservedArgument?
    let messageClassification: ConnectionMessageClassification?
    let observedLocation: ConnectionObservedLocation?
    let initial: Bool?
    let disposition: ConnectionObservationDisposition
    let invalidated: Bool
}

struct ConnectionDisplayObservation: Encodable, Sendable {
    let type = "display-connection-observation"
    let clock = "mach_continuous_time/ns"
    let role: InternalLifecycleRole
    let observerStartedAtNanoseconds: UInt64?
    let continuousNs: UInt64
    let flags: UInt32
    let scope: ConnectionDisplayScope
    let invalidationReason: String?
}

func connectionObservationMarker<Value: Encodable & Sendable>(_ observation: Value) throws -> String {
    String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
}

private let connectionObservationOutput = DispatchQueue(label: "Extilume.connection-observation-output")
// 退出兜底只处理已入队记录；正常停止在恢复后先收束观察器。
private let connectionObservationExitHook = atexit { connectionObservationOutput.sync {} }

func drainConnectionObservations(afterStoppingProducer stop: () -> Void) {
    stop()
    connectionObservationOutput.sync {}
}

func traceConnectionObservation<Value: Encodable & Sendable>(
    _ observation: Value,
    emit: @escaping @Sendable (String) -> Void = { print($0) }
) {
    _ = connectionObservationExitHook
    connectionObservationOutput.async {
        do { emit(try connectionObservationMarker(observation)) }
        catch { emit("连接事件关联记录不可用；不能据此证明事件归属。") }
    }
}
