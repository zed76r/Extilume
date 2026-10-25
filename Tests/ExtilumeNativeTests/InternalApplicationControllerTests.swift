import Darwin
import Foundation
import ExtilumeCore
import XCTest
@testable import ExtilumeNative

private final class InternalApplicationTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatuses: [PrimarySessionStatus] = []
    private var recordedArguments: [String]?
    private var recordedCommand: InternalApplicationCommand?
    private var recordedCompletion: Bool?
    private var partialFrameSent = false

    func append(_ status: PrimarySessionStatus) {
        lock.lock()
        recordedStatuses.append(status)
        lock.unlock()
    }

    func setArguments(_ value: [String]) {
        lock.lock()
        recordedArguments = value
        lock.unlock()
    }

    func setCommand(_ value: InternalApplicationCommand) {
        lock.lock()
        recordedCommand = value
        lock.unlock()
    }

    func setCompletion(_ value: Bool) {
        lock.lock()
        recordedCompletion = value
        lock.unlock()
    }

    func markPartialFrameSent() {
        lock.lock()
        partialFrameSent = true
        lock.unlock()
    }

    var statuses: [PrimarySessionStatus] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStatuses
    }

    var arguments: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    var command: InternalApplicationCommand? {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommand
    }

    var completion: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedCompletion
    }

    var didSendPartialFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return partialFrameSent
    }
}

@MainActor
final class InternalApplicationControllerTests: XCTestCase {
    func testInternalPrimaryCIsPreservedWhileTargetUsesExternalPrimary() throws {
        let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let confirmedC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1728, y: 120)
        ])
        let originalC = confirmedC

        let target = try internalApplicationTargetLayout(for: confirmedC, externalIdentity: externalID)

        XCTAssertEqual(target.main, externalID)
        XCTAssertEqual(target.origins[externalID], DisplayOrigin(x: 0, y: 0))
        XCTAssertEqual(target.origins[internalID], DisplayOrigin(x: -1728, y: -120))
        XCTAssertEqual(confirmedC, originalC)
        XCTAssertEqual(try layoutByMakingMain(target, target: internalID), confirmedC)
    }

    func testInternalApplicationExpectationKeepsTheFullConfirmedLayout() throws {
        let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!
        let hardware = InternalDisplayHardwareIdentity(
            bootSession: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!,
            registryEntryID: 99
        )
        let confirmedC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        let target = try internalApplicationTargetLayout(for: confirmedC, externalIdentity: externalID)
        let record = try RecoveryRecord(
            baseline: confirmedC,
            target: target,
            internalDisplay: InternalDisplayResponsibility(
                identity: internalID,
                baseline: true,
                applied: false,
                hardwareIdentity: hardware,
                numericIDHint: 80
            )
        )

        let expectation = try InternalApplicationExpectation(record: record)
        let decoded = try JSONDecoder().decode(
            InternalApplicationExpectation.self,
            from: JSONEncoder().encode(expectation)
        )

        XCTAssertEqual(decoded.baseline, confirmedC)
        XCTAssertEqual(decoded.internalIdentity, internalID)
        XCTAssertEqual(decoded.numericIDHint, 80)
        XCTAssertEqual(decoded.hardware, hardware)
    }

    func testSessionStatusesRoundTripThroughGuardChannelCodableShape() throws {
        let statuses: [PrimarySessionStatus] = [
            .applying, .applied, .manualConfiguration, .manualConfigurationForQuit,
            .applicationFailedRestored, .recoveryIncomplete, .unconfirmed,
            .confirmationFailed, .restoringAndQuitting, .quitFailed, .quitWaitingForDisplays,
            .unsupported("双屏布局不受支持")
        ]

        for status in statuses {
            XCTAssertEqual(
                try JSONDecoder().decode(PrimarySessionStatus.self, from: JSONEncoder().encode(status)),
                status
            )
        }
    }

    func testFinalProofRejectsDifferentSessionGenerationOrUnrestoredRecord() throws {
        let builtIn = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        let external = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
        let hardware = InternalDisplayHardwareIdentity(bootSession: UUID(), registryEntryID: 99)
        let baseline = try DisplayLayout(main: builtIn, origins: [builtIn: DisplayOrigin(x: 0, y: 0),
                                                                external: DisplayOrigin(x: 100, y: 0)])
        let record = try RecoveryRecord(baseline: baseline, target: baseline,
            internalDisplay: InternalDisplayResponsibility(identity: builtIn, baseline: true, applied: false,
                                                          hardwareIdentity: hardware, numericIDHint: 80))
        let expectation = try InternalApplicationExpectation(record: record)
        XCTAssertFalse(expectation.matchesRestoredRecord(record))
        var restored = record
        restored.beginRestoration()
        try restored.confirmRestored(actual: baseline, internalEnabled: true)
        XCTAssertTrue(expectation.matchesRestoredRecord(restored))
        for (key, value) in [("session", UUID().uuidString as Any), ("generation", 2 as Any)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            object[key] = value
            let other = try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(expectation.matchesRestoredRecord(other))
        }
    }

    func testPreflightClassificationRequiresNoPriorRecordAndNoHelper() {
        let waitingCases: [Error] = [
            InternalApplicationPreflightError.noExternalDisplay,
            InternalApplicationPreflightError.lidClosed
        ]
        for error in waitingCases {
            XCTAssertEqual(internalApplicationPreflightStatus(
                error: error,
                initialRecordExisted: false,
                recordIsAbsent: true,
                helperStarted: false
            ), .waiting)
        }

        let unsupportedCases: [Error] = [
            InternalApplicationPreflightError.unsupportedTopology,
            DisplayEnableTransactionError.symbolUnavailable
        ]
        for error in unsupportedCases {
            guard let status = internalApplicationPreflightStatus(
                error: error,
                initialRecordExisted: false,
                recordIsAbsent: true,
                helperStarted: false
            ), case .unsupported(_) = status else {
                return XCTFail("expected an unsupported status")
            }
        }

        XCTAssertNil(internalApplicationPreflightStatus(
            error: InternalApplicationPreflightError.noExternalDisplay,
            initialRecordExisted: true,
            recordIsAbsent: true,
            helperStarted: false
        ))
        XCTAssertNil(internalApplicationPreflightStatus(
            error: InternalApplicationPreflightError.noExternalDisplay,
            initialRecordExisted: false,
            recordIsAbsent: false,
            helperStarted: false
        ))
        XCTAssertNil(internalApplicationPreflightStatus(
            error: InternalApplicationPreflightError.noExternalDisplay,
            initialRecordExisted: false,
            recordIsAbsent: true,
            helperStarted: true
        ))
        XCTAssertNil(internalApplicationPreflightStatus(
            error: GuardError.identity,
            initialRecordExisted: false,
            recordIsAbsent: true,
            helperStarted: false
        ))
    }

    func testPreflightStatusRequiresParentExitDrainAndNilResponsibility() {
        let waiting = PrimarySessionStatus.waiting
        XCTAssertEqual(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: false,
            recordIsAbsent: true,
            expectationIsAbsent: true,
            helperStarted: false,
            workerExited: true,
            channelDrained: true
        ), waiting)
        XCTAssertNil(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: true,
            recordIsAbsent: true,
            expectationIsAbsent: true,
            helperStarted: false,
            workerExited: true,
            channelDrained: true
        ))
        XCTAssertNil(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: false,
            recordIsAbsent: false,
            expectationIsAbsent: true,
            helperStarted: false,
            workerExited: true,
            channelDrained: true
        ))
        XCTAssertNil(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: false,
            recordIsAbsent: true,
            expectationIsAbsent: true,
            helperStarted: true,
            workerExited: true,
            channelDrained: true
        ))
        XCTAssertNil(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: false,
            recordIsAbsent: true,
            expectationIsAbsent: true,
            helperStarted: false,
            workerExited: false,
            channelDrained: true
        ))
        XCTAssertNil(internalApplicationVerifiedPreflightStatus(
            waiting,
            initialRecordExisted: false,
            recordIsAbsent: true,
            expectationIsAbsent: true,
            helperStarted: false,
            workerExited: true,
            channelDrained: false
        ))
    }

    func testQuitDuringWorkerHandshakeLaunchesRecoveryOnly() throws {
        let directory = try makeControllerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = InternalApplicationTestRecorder()
        let allowHandshake = DispatchSemaphore(value: 0)
        let factory: InternalApplicationProcessFactory = { arguments, workerChannel in
            recorder.setArguments(arguments)
            DispatchQueue.global().async {
                do {
                    let request = try workerChannel.receive(InternalApplicationHandshakeRequest.self)
                    allowHandshake.wait()
                    try workerChannel.send(InternalApplicationEvent.ready(InternalApplicationHandshakeReply(
                        challenge: request.challenge,
                        workerPID: getpid(),
                        workerUID: UInt32(getuid())
                    )))
                    let command = try workerChannel.receive(InternalApplicationCommand.self)
                    recorder.setCommand(command)
                    try workerChannel.send(InternalApplicationEvent.failed)
                } catch {}
            }
            return getpid()
        }
        var controller: InternalApplicationController? = try InternalApplicationController(
            directory: directory,
            processFactory: factory
        )

        controller?.startApplication(registerEvents: false) { recorder.append($0) }
        controller?.quitApplication { recorder.setCompletion($0) }
        allowHandshake.signal()

        XCTAssertTrue(pumpMainRunLoop { recorder.command != nil && recorder.completion != nil })
        XCTAssertEqual(recorder.command, .start(recoveryOnly: true))
        XCTAssertEqual(recorder.completion, false)
        controller = nil
    }

    func testInjectedFactoryHandshakeFailureClosesChannelAndReportsRecoveryIncomplete() throws {
        let directory = try makeControllerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = InternalApplicationTestRecorder()
        let factory: InternalApplicationProcessFactory = { arguments, workerChannel in
            recorder.setArguments(arguments)
            DispatchQueue.global().async {
                _ = try? workerChannel.receive(InternalApplicationHandshakeRequest.self)
            }
            return getpid()
        }
        var controller: InternalApplicationController? = try InternalApplicationController(
            directory: directory,
            processFactory: factory
        )

        controller?.startApplication(registerEvents: false) { recorder.append($0) }

        XCTAssertTrue(pumpMainRunLoop { recorder.statuses.contains(.recoveryIncomplete) })
        XCTAssertEqual(recorder.arguments?.first, "--internal-app-session")
        XCTAssertEqual(recorder.arguments?.count, 3)
        controller = nil
    }

    func testInjectedFactoryPartialIPCClosesChannelWithoutBlockingMainRunLoop() throws {
        let directory = try makeControllerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = InternalApplicationTestRecorder()
        let allowPeerClose = DispatchSemaphore(value: 0)
        let factory: InternalApplicationProcessFactory = { _, workerChannel in
            DispatchQueue.global().async {
                do {
                    let request = try workerChannel.receive(InternalApplicationHandshakeRequest.self)
                    try workerChannel.send(InternalApplicationEvent.ready(InternalApplicationHandshakeReply(
                        challenge: request.challenge,
                        workerPID: getpid(),
                        workerUID: UInt32(getuid())
                    )))
                    let command = try workerChannel.receive(InternalApplicationCommand.self)
                    recorder.setCommand(command)
                    var length = UInt32(40).bigEndian
                    let header = withUnsafeBytes(of: &length) { Data($0) }
                    var partial = header
                    partial.append(0x7b)
                    _ = partial.withUnsafeBytes { bytes in
                        Darwin.send(workerChannel.descriptor, bytes.baseAddress!, bytes.count, 0)
                    }
                    recorder.markPartialFrameSent()
                    allowPeerClose.wait()
                } catch {}
            }
            return getpid()
        }
        var controller: InternalApplicationController? = try InternalApplicationController(
            directory: directory,
            processFactory: factory
        )

        controller?.startApplication(registerEvents: false) { recorder.append($0) }

        XCTAssertTrue(pumpMainRunLoop { recorder.didSendPartialFrame })
        let heartbeat = DispatchSemaphore(value: 0)
        let startedAt = Date()
        RunLoop.main.perform(inModes: [.modalPanel]) {
            heartbeat.signal()
            allowPeerClose.signal()
        }
        _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.25))
        XCTAssertEqual(heartbeat.wait(timeout: .now()), .success)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertTrue(pumpMainRunLoop(mode: .modalPanel) { recorder.statuses.contains(.recoveryIncomplete) })
        XCTAssertEqual(recorder.command, .start(recoveryOnly: false))
        controller = nil
    }

    private func makeControllerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("internal-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func pumpMainRunLoop(until condition: () -> Bool) -> Bool {
        pumpMainRunLoop(mode: .default, until: condition)
    }

    private func pumpMainRunLoop(mode: RunLoop.Mode, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
