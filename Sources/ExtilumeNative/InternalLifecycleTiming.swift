import CoreGraphics
import ExtilumeCore
import Foundation

enum InternalLifecycleStage: String, Encodable {
    case sleepRequested, sleepWaitFinished, powerAcknowledged, systemHasPoweredOn
    case firstConnectionInvalidation, restorationStarted, internalReadStarted, internalReadFinished
    case enableStarted, enableFinished, layoutReadStarted, layoutReadFinished
    case originsStarted, originsFinished, restorationVerified
    case observerDrainStarted, observerDrainFinished, pauseVerificationStarted, pauseVerificationFinished
    case enableIdentityReadStarted, enableIdentityReadFinished
    case enablePreValidationStarted, enablePreValidationFinished, enableBeginStarted, enableBeginFinished
    case enableConfigureStarted, enableConfigureFinished, enablePostValidationStarted, enablePostValidationFinished
    case enableCompleteStarted, enableCompleteFinished, enableCancelStarted, enableCancelFinished
    case restorationFailed, powerAcknowledgementStarted, powerAcknowledgementFinished
}

enum InternalLifecycleRole: String, Encodable { case controller, helper, recoveryEntry }

private struct InternalLifecycleMarker: Encodable {
    let type = "internal-lifecycle"
    let clock = "mach_continuous_time/ns"
    let role: InternalLifecycleRole
    let stage: InternalLifecycleStage
    let continuousNs: UInt64
    let mainThread: Bool
    let succeeded: Bool?
    let cgErrorCode: Int32?
    let failureCode: String?
}

func internalLifecycleMarker(
    _ stage: InternalLifecycleStage, role: InternalLifecycleRole = .controller,
    at timestamp: UInt64, mainThread: Bool, succeeded: Bool? = nil,
    cgError: CGError? = nil, error: Error? = nil
) throws -> String {
    String(decoding: try JSONEncoder().encode(InternalLifecycleMarker(
        role: role, stage: stage, continuousNs: timestamp, mainThread: mainThread,
        succeeded: succeeded ?? cgError.map { $0 == .success },
        cgErrorCode: cgError?.rawValue, failureCode: error.map(snapshotWitnessFailureCode)
    )), as: UTF8.self)
}

func traceInternalLifecycle(
    _ stage: InternalLifecycleStage, role: InternalLifecycleRole = .controller,
    succeeded: Bool? = nil, observedAt: UInt64? = nil,
    cgError: CGError? = nil, error: Error? = nil
) {
    do {
        let timestamp = try observedAt ?? ContinuousClock.nanoseconds()
        print(try internalLifecycleMarker(stage, role: role, at: timestamp,
                                         mainThread: Thread.isMainThread, succeeded: succeeded,
                                         cgError: cgError, error: error))
    } catch {
        print("内屏生命周期计时不可用；不能据此判定恢复时限通过。")
    }
}
