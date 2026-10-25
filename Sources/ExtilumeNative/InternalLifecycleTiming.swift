import CoreGraphics
import ExtilumeCore
import Foundation

enum InternalLifecycleStage: String, Encodable {
    case sleepRequested, sleepWaitFinished, powerAcknowledged, systemHasPoweredOn
    case firstConnectionInvalidation, restorationStarted, internalReadStarted, internalReadFinished
    case enableStarted, enableFinished, layoutReadStarted, layoutReadFinished
    case originsStarted, originsFinished, restorationVerified, layoutRestoreRejected
    case observerDrainStarted, observerDrainFinished, pauseVerificationStarted, pauseVerificationFinished
    case enableIdentityReadStarted, enableIdentityReadFinished
    case enablePreValidationStarted, enablePreValidationFinished, enableBeginStarted, enableBeginFinished
    case enableConfigureStarted, enableConfigureFinished, enablePostValidationStarted, enablePostValidationFinished
    case enableCompleteStarted, enableCompleteFinished, enableCancelStarted, enableCancelFinished
    case restorationFailed, powerAcknowledgementStarted, powerAcknowledgementFinished
    case internalIdentityRejected, internalCandidateUnavailable
    case witnessSpawnStarted, witnessSpawnFinished, witnessRequestStarted, witnessRequestFinished
    case witnessReplyStarted, witnessReplyFinished, witnessExitStarted, witnessExitFinished
    case witnessFailed, witnessCleanupStarted, witnessCleanupFinished
    case witnessRequestReceived, witnessReadStarted, witnessReadFinished
    case internalOnlineReadStarted, internalOnlineReadFinished, internalActiveReadStarted, internalActiveReadFinished
    case internalCandidateReadStarted, internalCandidateReadFinished
    case disableStarted, disableFinished, disableFailed
    case linkReconfigurationStarted, linkReconfigurationCollected, linkReconfigurationVerified, linkReconfigurationFailed
}

enum InternalLifecycleRole: String, Encodable, Sendable { case controller, helper, recoveryEntry, witness, observer }
enum InternalDisplayOperation: String, Encodable { case disable, enable }

enum InternalDisplayCandidateFailure: String, Encodable {
    case informationUnavailable, numericIDMismatch, missingUUID, malformedUUID
}

struct InternalRecoveryLayoutContext: Encodable, Equatable {
    let matchesBaseline: Bool
    let matchesApplied: Bool
    let matchesPreDisable: Bool
    let matchesBaselineDisplaySet: Bool
    let isBaselineDisplaySubset: Bool
    let layoutPending: Bool
    let internalPending: Bool?
    let sourceUnresolved: Bool

    init(record: RecoveryRecord, current: DisplayLayout) {
        matchesBaseline = current == record.baseline
        matchesApplied = current == record.applied
        matchesPreDisable = current == record.preDisableLayout
        matchesBaselineDisplaySet = Set(current.origins.keys) == Set(record.baseline.origins.keys)
        isBaselineDisplaySubset = Set(current.origins.keys).isSubset(of: Set(record.baseline.origins.keys))
        layoutPending = record.layoutPending
        internalPending = record.internalDisplay?.pending
        sourceUnresolved = record.sourceUnresolved
    }
}

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
    let identityFailure: InternalDisplayIdentityFailure?
    let candidateFailure: InternalDisplayCandidateFailure?
    let isNumericHint: Bool?
    let operation: InternalDisplayOperation?
    let recoveryLayout: InternalRecoveryLayoutContext?
}

func internalLifecycleMarker(
    _ stage: InternalLifecycleStage, role: InternalLifecycleRole = .controller,
    at timestamp: UInt64, mainThread: Bool, succeeded: Bool? = nil,
    cgError: CGError? = nil, error: Error? = nil,
    identityFailure: InternalDisplayIdentityFailure? = nil,
    candidateFailure: InternalDisplayCandidateFailure? = nil, isNumericHint: Bool? = nil,
    operation: InternalDisplayOperation? = nil,
    recoveryLayout: InternalRecoveryLayoutContext? = nil
) throws -> String {
    String(decoding: try JSONEncoder().encode(InternalLifecycleMarker(
        role: role, stage: stage, continuousNs: timestamp, mainThread: mainThread,
        succeeded: succeeded ?? cgError.map { $0 == .success },
        cgErrorCode: cgError?.rawValue, failureCode: error.map(snapshotWitnessFailureCode),
        identityFailure: identityFailure, candidateFailure: candidateFailure, isNumericHint: isNumericHint,
        operation: operation, recoveryLayout: recoveryLayout
    )), as: UTF8.self)
}

func traceInternalLifecycle(
    _ stage: InternalLifecycleStage, role: InternalLifecycleRole = .controller,
    succeeded: Bool? = nil, observedAt: UInt64? = nil,
    cgError: CGError? = nil, error: Error? = nil,
    identityFailure: InternalDisplayIdentityFailure? = nil,
    candidateFailure: InternalDisplayCandidateFailure? = nil, isNumericHint: Bool? = nil,
    operation: InternalDisplayOperation? = nil,
    recoveryLayout: InternalRecoveryLayoutContext? = nil
) {
    do {
        let timestamp = try observedAt ?? ContinuousClock.nanoseconds()
        print(try internalLifecycleMarker(stage, role: role, at: timestamp,
                                         mainThread: Thread.isMainThread, succeeded: succeeded,
                                         cgError: cgError, error: error, identityFailure: identityFailure,
                                         candidateFailure: candidateFailure, isNumericHint: isNumericHint,
                                         operation: operation, recoveryLayout: recoveryLayout))
    } catch {
        print("内屏生命周期计时不可用；不能据此判定恢复时限通过。")
    }
}
