import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class RecoverySuspensionRecorderTests: XCTestCase {
    func testRecordsPairedSamplesOnlyAfterAcknowledgement() throws {
        let session = UUID()
        let fake = FakeReads(
            samples: [
                try sample(session, 10, 10, 10),
                try sample(session, 40, 20, 40)
            ],
            continuous: [10, 30]
        )
        let state = fake.state(session)

        XCTAssertTrue(state.prepareForSleep())
        state.didPrepareForSleep(accepted: true, acknowledged: true)
        state.didWake()

        let interval = try XCTUnwrap(state.evidence().intervals.first)
        XCTAssertEqual(state.evidence().intervals.count, 1)
        XCTAssertEqual(interval.before.continuousBeforeNanoseconds, 10)
        XCTAssertEqual(interval.powerEvent.willSleepAtNanoseconds, 10)
        XCTAssertEqual(interval.powerEvent.didWakeAtNanoseconds, 30)
        XCTAssertEqual(interval.after.continuousBeforeNanoseconds, 40)
    }

    func testFailedAcknowledgementDuplicateSleepAndUnmatchedWakeYieldNoEvidence() throws {
        let session = UUID()
        let failedAck = FakeReads(samples: [try sample(session, 10, 10, 10)], continuous: [10])
        let failedState = failedAck.state(session)
        XCTAssertTrue(failedState.prepareForSleep())
        failedState.didPrepareForSleep(accepted: true, acknowledged: false)
        failedState.didWake()
        XCTAssertTrue(failedState.evidence().intervals.isEmpty)

        let repeated = FakeReads(samples: [try sample(session, 10, 10, 10)], continuous: [10])
        let repeatedState = repeated.state(session)
        XCTAssertTrue(repeatedState.prepareForSleep())
        XCTAssertTrue(repeatedState.prepareForSleep())
        repeatedState.didPrepareForSleep(accepted: true, acknowledged: true)
        repeatedState.didWake()
        XCTAssertEqual(repeated.sampleReads, 1, "a repeated sleep must not replace the first sample")
        XCTAssertTrue(repeatedState.evidence().intervals.isEmpty)

        let unmatched = FakeReads(samples: [], continuous: [])
        let unmatchedState = unmatched.state(session)
        unmatchedState.didWake()
        XCTAssertTrue(unmatchedState.evidence().intervals.isEmpty)
    }

    func testSampleFailureInvalidatesTheWholeCollection() throws {
        let session = UUID()
        let fake = FakeReads(samples: [], continuous: [10])
        fake.failSamples = true
        let state = fake.state(session)

        XCTAssertTrue(state.prepareForSleep())
        state.didPrepareForSleep(accepted: true, acknowledged: true)
        state.didWake()
        XCTAssertTrue(state.evidence().intervals.isEmpty)
    }

    func testEvidenceWriterUsesPrivateModesAndNeverOverwrites() throws {
        let session = UUID()
        let before = try sample(session, 10, 10, 10)
        let after = try sample(session, 40, 20, 40)
        let evidence = RecoverySuspensionEvidence(intervals: [
            RecoverySuspensionInterval(
                before: before,
                after: after,
                powerEvent: RecoveryPowerEventEvidence(
                    bootSession: session,
                    willSleepAtNanoseconds: 10,
                    didWakeAtNanoseconds: 30
                )
            )
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("suspension-evidence.json")

        try writeRecoverySuspensionEvidence(evidence, to: file.path)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(RecoverySuspensionEvidence.self, from: Data(contentsOf: file)), evidence)
        XCTAssertThrowsError(try writeRecoverySuspensionEvidence(RecoverySuspensionEvidence(intervals: []), to: file.path))
        XCTAssertEqual(try JSONDecoder().decode(RecoverySuspensionEvidence.self, from: Data(contentsOf: file)), evidence)
    }

    private func sample(_ session: UUID, _ before: UInt64, _ awake: UInt64, _ after: UInt64) throws -> RecoveryClockSample {
        try RecoveryClockSample(
            bootSession: session,
            continuousBeforeNanoseconds: before,
            awakeNanoseconds: awake,
            continuousAfterNanoseconds: after
        )
    }

    private final class FakeReads: @unchecked Sendable {
        var samples: [RecoveryClockSample]
        var continuous: [UInt64]
        var failSamples = false
        private(set) var sampleReads = 0

        init(samples: [RecoveryClockSample], continuous: [UInt64]) {
            self.samples = samples
            self.continuous = continuous
        }

        func state(_ session: UUID) -> RecoverySuspensionRecorderState {
            RecoverySuspensionRecorderState(
                bootSession: session,
                readSample: { [self] _ in
                    sampleReads += 1
                    if failSamples { throw RecoveryClockSampleError.invalidOrder }
                    guard !samples.isEmpty else { throw RecoveryClockSampleError.invalidOrder }
                    return samples.removeFirst()
                },
                readContinuous: { [self] in
                    guard !continuous.isEmpty else { throw RecoveryClockSampleError.invalidOrder }
                    return continuous.removeFirst()
                }
            )
        }
    }
}
