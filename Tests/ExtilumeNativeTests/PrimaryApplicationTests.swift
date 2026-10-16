import CoreGraphics
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class PrimaryApplicationTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let foreignID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    func testWaitsWithoutExternalDisplayAndRejectsMirroring() throws {
        let waitingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: waitingDirectory) }
        let waitingFixture = ControllerFixture(snapshot: try makeSnapshot(try layout(), includeExternal: false))
        let waitingStatuses = StatusRecorder()
        var waitingController: PrimaryController? = try makeController(directory: waitingDirectory, fixture: waitingFixture)
        waitingController?.startApplication(registerEvents: false) { waitingStatuses.append($0) }

        XCTAssertTrue(waitingStatuses.wait { $0 == .waiting })
        XCTAssertTrue(waitingFixture.writes.isEmpty)
        XCTAssertNil(try readRecord(in: waitingDirectory))
        waitingController = nil

        let mirroredDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: mirroredDirectory) }
        let mirroredFixture = ControllerFixture(snapshot: try makeSnapshot(try layout(), mirrored: true))
        let mirroredStatuses = StatusRecorder()
        var mirroredController: PrimaryController? = try makeController(directory: mirroredDirectory, fixture: mirroredFixture)
        mirroredController?.startApplication(registerEvents: false) { mirroredStatuses.append($0) }

        XCTAssertTrue(mirroredStatuses.wait {
            if case .unsupported = $0 { return true }
            return false
        })
        XCTAssertTrue(mirroredFixture.writes.isEmpty)
        XCTAssertNil(try readRecord(in: mirroredDirectory))
        mirroredController = nil
    }

    func testSuccessfulTakeoverPersistsOwnedRecordAndReadsBackB() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait { $0 == .applied })
        let record = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(record.phase, .owned)
        XCTAssertEqual(record.baseline, baseline)
        XCTAssertEqual(record.applied, target)
        XCTAssertEqual(try fixture.snapshot().layout(), target)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertTrue(fixture.writes[0].appOnly)
        XCTAssertEqual(fixture.writes[0].origins, [
            40: DisplayOrigin(x: 0, y: 0),
            80: DisplayOrigin(x: -1728, y: 0)
        ])

        let recordPath = directory.appendingPathComponent("recovery-record.json")
        let fileMode = (try FileManager.default.attributesOfItem(atPath: recordPath.path)[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(fileMode.map { $0 & 0o7777 }, 0o600)
        XCTAssertEqual(directoryMode.map { $0 & 0o7777 }, 0o700)
        controller = nil
    }

    func testApplicationFailureRestoresAndCanBeRetried() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let writer: OriginWriter = { origins, option in
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
            if fixture.writes.count == 1 { throw FixtureError.injected }
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait { $0 == .applicationFailedRestored })
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])

        controller?.retryApplication()
        XCTAssertTrue(statuses.wait { $0 == .applied })
        let retried = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retried.phase, .owned)
        XCTAssertNotEqual(retried.session, restored.session)
        XCTAssertEqual(try fixture.snapshot().layout(), target)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false, true])
        controller = nil
    }

    func testFailedQuitKeepsRecordAndRecoveryCanRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let writer: OriginWriter = { origins, option in
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
            if fixture.writes.count == 2 { throw FixtureError.injected }
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait { $0 == .applied })

        let completion = CompletionRecorder()
        controller?.quitApplication { completion.finish($0) }
        XCTAssertEqual(completion.wait(), false)
        XCTAssertTrue(statuses.wait { $0 == .quitFailed })
        let interrupted = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(interrupted.phase, .restoring)
        XCTAssertFalse(interrupted.canClear)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)

        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait { $0 == .applicationFailedRestored })
        let recovered = try XCTUnwrap(readRecord(in: directory))
        XCTAssertTrue(recovered.canClear)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false, false])
        controller = nil
    }

    func testRepeatedRetryClicksDoNotQueueMoreFailedApplications() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ControllerFixture(snapshot: try makeSnapshot(try layout()))
        let statuses = StatusRecorder()
        let retryEntered = DispatchSemaphore(value: 0)
        let continueRetry = DispatchSemaphore(value: 0)
        let controller = try makeController(directory: directory, fixture: fixture) { origins, option in
            let call = fixture.recordWrite(origins, option: option)
            if call.index == 3 {
                retryEntered.signal()
                guard continueRetry.wait(timeout: .now() + 4) == .success else { throw FixtureError.timeout }
            }
            fixture.applyOrigins(origins)
            if option == .forAppOnly { throw FixtureError.injected }
        }
        controller.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        controller.retryApplication()
        let entered = retryEntered.wait(timeout: .now() + 2)
        if entered == .success {
            for _ in 0..<10 { controller.retryApplication() }
        }
        continueRetry.signal()
        XCTAssertEqual(entered, .success)
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored, count: 2))
        let completion = CompletionRecorder()
        controller.quitApplication { completion.finish($0) }
        XCTAssertEqual(completion.wait(), true)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false, true, false, false])
    }

    func testRetryRequestedFromTerminalStatusIsAccepted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ControllerFixture(snapshot: try makeSnapshot(try layout()))
        let statuses = StatusRecorder()
        let controller = try makeController(directory: directory, fixture: fixture) { origins, option in
            let call = fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
            if option == .forAppOnly && call.index < 5 { throw FixtureError.injected }
        }
        controller.startApplication(registerEvents: false) { [weak controller] status in
            statuses.append(status)
            if status == .applicationFailedRestored { controller?.retryApplication() }
        }
        XCTAssertTrue(statuses.wait(for: .applied))
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false, true, false, true])
    }

    func testPriorRecordRestoresBeforeNewApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = try seedOwnedRecord(in: directory)
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(target))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait { $0 == .applied })
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertFalse(fixture.writes[0].appOnly)
        XCTAssertEqual(fixture.writes[0].origins, [
            40: DisplayOrigin(x: 1728, y: 0),
            80: DisplayOrigin(x: 0, y: 0)
        ])
        XCTAssertTrue(fixture.writes[1].appOnly)
        XCTAssertEqual(try fixture.snapshot().layout(), target)

        let current = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(current.phase, .owned)
        XCTAssertNotEqual(current.session, prior.session)
        XCTAssertEqual(current.baseline, baseline)
        XCTAssertEqual(current.applied, target)
        controller = nil
    }

    func testForeignDisplayIdentityCannotReplacePriorRecord() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = try seedOwnedRecord(in: directory)
        let foreignLayout = try layout(externalIdentity: foreignID)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(foreignLayout, externalIdentity: foreignID))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait { $0 == .recoveryIncomplete })
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(try readRecord(in: directory), prior)
        controller = nil
    }

    func testCorruptPriorRecordCannotBeReportedAsRestored() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recovery-record.json")
        let original = Data("invalid record".utf8)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(try layout()))
        let statuses = StatusRecorder()
        let controller = try makeController(directory: directory, fixture: fixture)
        controller.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        controller.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete, count: 2))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testDisplayCallbackCannotHideFailedRestoration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ControllerFixture(snapshot: try makeSnapshot(try layout()))
        let statuses = StatusRecorder()
        let controller = try makeController(directory: directory, fixture: fixture) { origins, option in
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
            throw FixtureError.injected
        }
        controller.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        controller.displayChanged(.desktopShapeChangedFlag)
        controller.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete, count: 2))
        XCTAssertFalse(try XCTUnwrap(readRecord(in: directory)).canClear)
    }

    func testUnknownSourceAtBaselineCanBeExplicitlyRecoveredAndRecordRetained() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)

        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        let writes = fixture.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map(\.appOnly), [true, false])
        XCTAssertEqual(writes.dropFirst().map(\.origins), [[
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ]])
        controller = nil
    }

    func testUnknownSourceAtBaselineCanQuitAfterRestorationAndRetainsRecord() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)

        let completion = CompletionRecorder()
        controller?.quitApplication { completion.finish($0) }
        XCTAssertEqual(completion.wait(), true)
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        let writes = fixture.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map(\.appOnly), [true, false])
        XCTAssertEqual(writes.dropFirst().map(\.origins), [[
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ]])
        controller = nil
    }

    func testUnknownSourceAtDifferentLayoutCannotBeRecoveredOrQuit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let layoutC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertNotEqual(layoutC, baseline)
        XCTAssertNotEqual(layoutC, target)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))

        fixture.setSnapshot(try makeSnapshot(layoutC))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)
        let writesBeforeRecovery = fixture.writes

        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .unconfirmed, count: 2))
        let completion = CompletionRecorder()
        controller?.quitApplication { completion.finish($0) }
        XCTAssertEqual(completion.wait(), false)

        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.baseline, baseline)
        XCTAssertTrue(retained.sourceUnresolved)
        XCTAssertEqual(fixture.writes, writesBeforeRecovery)
        XCTAssertEqual(try fixture.snapshot().layout(), layoutC)
        controller = nil
    }

    func testConfirmCurrentConfigurationPromotesUnknownLayoutWithoutWritingDisplays() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let writesBeforeConfirmation = session.fixture.writes

        session.controller?.confirmCurrentConfiguration()

        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        let confirmed = try XCTUnwrap(readRecord(in: session.directory))
        XCTAssertEqual(confirmed.session, session.original.session)
        XCTAssertEqual(confirmed.generation, session.original.generation)
        XCTAssertEqual(confirmed.phase, .owned)
        XCTAssertEqual(confirmed.baseline, session.current)
        XCTAssertEqual(confirmed.applied, session.original.applied)
        XCTAssertFalse(confirmed.layoutPending)
        XCTAssertFalse(confirmed.sourceUnresolved)
        XCTAssertEqual(session.fixture.writes, writesBeforeConfirmation)
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testConfirmedConfigurationCanQuitDirectlyAtC() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        session.controller?.confirmCurrentConfiguration()
        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        let completion = CompletionRecorder()
        session.controller?.quitApplication { completion.finish($0) }

        XCTAssertEqual(completion.wait(), true)
        let restored = try XCTUnwrap(readRecord(in: session.directory))
        XCTAssertEqual(restored.session, session.original.session)
        XCTAssertEqual(restored.generation, session.original.generation)
        XCTAssertEqual(restored.baseline, session.current)
        XCTAssertTrue(restored.canClear)
        let writes = session.fixture.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map(\.appOnly), [true, false])
        XCTAssertEqual(writes[1].origins, [
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testConfirmationAfterFailedQuitKeepsTakeoverStoppedAndCanExitAtC() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let firstQuit = CompletionRecorder()
        session.controller?.quitApplication { firstQuit.finish($0) }
        XCTAssertEqual(firstQuit.wait(), false)
        XCTAssertTrue(session.statuses.wait(for: .quitFailed))
        session.controller?.confirmCurrentConfiguration()
        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        session.controller?.systemDidWake()
        XCTAssertFalse(session.statuses.wait(for: .applied, count: 2, timeout: 1.2))
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        let retryQuit = CompletionRecorder()
        session.controller?.quitApplication { retryQuit.finish($0) }
        XCTAssertEqual(retryQuit.wait(), true)
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)).baseline, session.current)
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testConfirmedCResumesThroughApplicationLayoutAndQuitsBackToC() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let resumedB = try DisplayLayout(main: externalID, origins: [
            internalID: DisplayOrigin(x: -1920, y: 0),
            externalID: DisplayOrigin(x: 0, y: 0)
        ])

        session.controller?.confirmCurrentConfiguration()
        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        session.controller?.systemWillSleep()
        XCTAssertTrue(session.statuses.wait(for: .unsupported("系统睡眠中，等待唤醒")))
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller?.systemDidWake()
        XCTAssertTrue(session.statuses.wait(for: .applied, count: 2))

        let afterWake = try XCTUnwrap(readRecord(in: session.directory))
        XCTAssertEqual(afterWake.session, session.original.session)
        XCTAssertEqual(afterWake.baseline, session.current)
        XCTAssertEqual(afterWake.applied, resumedB)
        XCTAssertEqual(afterWake.generation, session.original.generation + 1)
        XCTAssertTrue(afterWake.layoutPending)
        XCTAssertFalse(afterWake.sourceUnresolved)
        XCTAssertEqual(session.fixture.writes.count, 2)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true, true])
        XCTAssertEqual(session.fixture.writes[1].origins, [
            80: DisplayOrigin(x: -1920, y: 0),
            40: DisplayOrigin(x: 0, y: 0)
        ])

        let completion = CompletionRecorder()
        session.controller?.quitApplication { completion.finish($0) }
        XCTAssertEqual(completion.wait(), true)
        let restored = try XCTUnwrap(readRecord(in: session.directory))
        XCTAssertEqual(restored.session, session.original.session)
        XCTAssertEqual(restored.baseline, session.current)
        XCTAssertTrue(restored.canClear)
        let writes = session.fixture.writes
        XCTAssertEqual(writes.map(\.appOnly), [true, true, false])
        XCTAssertEqual(writes[2].origins, [
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testConfirmCurrentConfigurationRejectsOwnedB() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        session.fixture.setSnapshot(try makeSnapshot(session.target))

        session.controller?.confirmCurrentConfiguration()

        XCTAssertTrue(session.statuses.wait(for: .confirmationFailed))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.target)
        session.controller = nil
    }

    func testConfirmCurrentConfigurationRejectsMissingForeignAndMirroredLayouts() throws {
        let current = try selectedLayoutC()
        let foreign = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            foreignID: DisplayOrigin(x: 1920, y: 0)
        ])

        try assertConfirmationRejected(with: makeSnapshot(current, includeInternal: false))
        try assertConfirmationRejected(with: makeSnapshot(foreign, externalIdentity: foreignID))
        try assertConfirmationRejected(with: makeSnapshot(current, mirrored: true))
    }

    func testConfirmCurrentConfigurationDoesNotCommitWhenThirdSnapshotDrifts() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let drifted = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 2048, y: 0)
        ])
        session.fixture.setSnapshotSequence([
            try makeSnapshot(session.current),
            try makeSnapshot(session.current),
            try makeSnapshot(drifted)
        ])

        session.controller?.confirmCurrentConfiguration()

        XCTAssertTrue(session.statuses.wait(for: .confirmationFailed))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testDisplayEventInvalidatesConfirmationWhileSnapshotReadIsBlocked() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let gate = session.fixture.blockSnapshotRead(after: 3)
        defer { gate.release() }

        session.controller?.confirmCurrentConfiguration()
        let entered = gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { session.controller = nil; return }

        session.controller?.displayChanged(.desktopShapeChangedFlag)
        gate.release()

        XCTAssertTrue(session.statuses.wait(for: .confirmationFailed))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        XCTAssertEqual(try session.fixture.snapshot().layout(), session.current)
        session.controller = nil
    }

    func testDuplicateConfirmationRequestIsIgnoredWhileFirstRequestIsPending() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let gate = session.fixture.blockSnapshotRead(after: 3)
        defer { gate.release() }

        session.controller?.confirmCurrentConfiguration()
        let entered = gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { session.controller = nil; return }
        session.controller?.confirmCurrentConfiguration()
        gate.release()

        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        XCTAssertFalse(session.statuses.wait(for: .confirmationFailed, timeout: 0.1))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)).baseline, session.current)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        session.controller = nil
    }

    func testSleepInvalidatesConfirmationBeforeCommit() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let gate = session.fixture.blockSnapshotRead(after: 3)
        defer { gate.release() }
        session.controller?.confirmCurrentConfiguration()
        let entered = gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { session.controller = nil; return }
        session.controller?.systemWillSleep()
        gate.release()
        XCTAssertTrue(session.statuses.wait(for: .confirmationFailed))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        session.controller = nil
    }

    func testConfirmationSaveFailurePreservesRecordAndCanBeRetried() throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let recordURL = session.directory.appendingPathComponent("recovery-record.json")
        let originalBytes = try Data(contentsOf: recordURL)
        let gate = session.fixture.blockSnapshotRead(after: 3)
        defer {
            gate.release()
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.directory.path)
        }

        session.controller?.confirmCurrentConfiguration()
        let entered = gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { session.controller = nil; return }

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: session.directory.path)
        gate.release()
        XCTAssertTrue(session.statuses.wait(for: .recoveryIncomplete))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.directory.path)

        XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])

        session.controller?.recoverApplication()
        XCTAssertTrue(session.statuses.wait(for: .unconfirmed, count: 2))
        XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
        session.controller?.confirmCurrentConfiguration()
        XCTAssertTrue(session.statuses.wait(for: .manualConfiguration))
        let confirmed = try XCTUnwrap(readRecord(in: session.directory))
        XCTAssertEqual(confirmed.baseline, session.current)
        XCTAssertFalse(confirmed.sourceUnresolved)
        XCTAssertFalse(confirmed.layoutPending)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        session.controller = nil
    }

    func testRecoveryDoesNotWriteWhenSecondSnapshotChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let layoutC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertNotEqual(layoutC, baseline)
        XCTAssertNotEqual(layoutC, target)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        let writesBeforeRecovery = fixture.writes
        fixture.setSnapshotSequence([try makeSnapshot(baseline), try makeSnapshot(layoutC)])

        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.baseline, baseline)
        XCTAssertTrue(retained.sourceUnresolved)
        XCTAssertFalse(retained.canClear)
        XCTAssertEqual(fixture.writes, writesBeforeRecovery)
        controller = nil
    }

    func testClosedLidDefersReapplicationUntilFullBaselineReturns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        fixture.setLid("合盖")
        fixture.setSnapshot(try makeSnapshot(target, includeInternal: false))
        let statusCount = statuses.count
        controller?.displayChanged(.disabledFlag)
        XCTAssertTrue(statuses.wait(for: { _ in true }, count: statusCount + 1))
        let duringLidClose = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(duringLidClose.session, original.session)
        XCTAssertEqual(duringLidClose.baseline, baseline)
        XCTAssertEqual(duringLidClose.generation, original.generation)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])

        fixture.setLid("开盖")
        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .applied, count: 2))
        let reapplied = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(reapplied.session, original.session)
        XCTAssertEqual(reapplied.baseline, baseline)
        XCTAssertEqual(reapplied.generation, 2)
        XCTAssertEqual(reapplied.phase, .owned)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, true])
        XCTAssertEqual(try fixture.snapshot().layout(), target)
        controller = nil
    }

    func testClosedLidUnknownLayoutStaysUnresolvedAfterOpeningAtBaseline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let layoutC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertNotEqual(layoutC, baseline)
        XCTAssertNotEqual(layoutC, target)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let unresolvedAtRestoreWrite = CompletionRecorder()
        let writer: OriginWriter = { origins, option in
            if option == .forSession {
                unresolvedAtRestoreWrite.finish(try RecoveryStore(directory: directory).load()?.sourceUnresolved ?? false)
            }
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        fixture.setLid("合盖")
        fixture.setSnapshot(try makeSnapshot(layoutC))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)

        fixture.setLid("开盖")
        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.addFlag)
        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.session, original.session)
        XCTAssertEqual(retained.baseline, baseline)
        XCTAssertTrue(retained.canClear)
        XCTAssertFalse(retained.sourceUnresolved)
        XCTAssertEqual(unresolvedAtRestoreWrite.wait(), true)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        XCTAssertEqual(fixture.writes.dropFirst().map(\.origins), [[
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ]])
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        controller = nil
    }

    func testReturningToBaselineWithoutObservedLidCloseRemainsUnconfirmed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.session, original.session)
        XCTAssertEqual(retained.baseline, baseline)
        XCTAssertTrue(retained.sourceUnresolved)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])
        controller = nil
    }

    func testSleepAndRepeatedWakeReapplyOnceAtOriginalBaseline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        controller?.systemWillSleep()
        XCTAssertTrue(statuses.wait(for: .unsupported("系统睡眠中，等待唤醒")))
        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        controller?.systemWillSleep()
        controller?.systemDidWake()
        controller?.systemDidWake()

        XCTAssertTrue(statuses.wait(for: .applied, count: 2))
        let reapplied = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(reapplied.session, original.session)
        XCTAssertEqual(reapplied.baseline, baseline)
        XCTAssertFalse(reapplied.sourceUnresolved)
        XCTAssertEqual(reapplied.generation, 2)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, true])
        XCTAssertEqual(try fixture.snapshot().layout(), target)
        controller = nil
    }

    func testUnknownLayoutDuringSleepStaysUnresolvedAcrossWake() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let layoutC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        XCTAssertNotEqual(layoutC, baseline)
        XCTAssertNotEqual(layoutC, target)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let unresolvedAtRestoreWrite = CompletionRecorder()
        let writer: OriginWriter = { origins, option in
            if option == .forSession {
                unresolvedAtRestoreWrite.finish(try RecoveryStore(directory: directory).load()?.sourceUnresolved ?? false)
            }
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        controller?.systemWillSleep()
        XCTAssertTrue(statuses.wait(for: .unsupported("系统睡眠中，等待唤醒")))
        fixture.setSnapshot(try makeSnapshot(layoutC))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.systemDidWake()
        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(restored.session, original.session)
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertTrue(restored.canClear)
        XCTAssertFalse(restored.sourceUnresolved)
        XCTAssertEqual(unresolvedAtRestoreWrite.wait(), true)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        XCTAssertEqual(fixture.writes.dropFirst().map(\.origins), [[
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ]])
        controller = nil
    }

    func testSleepWakeCannotClearAnEarlierUnknownBaselineObservation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let unresolvedAtRestoreWrite = CompletionRecorder()
        let writer: OriginWriter = { origins, option in
            if option == .forSession {
                unresolvedAtRestoreWrite.finish(try RecoveryStore(directory: directory).load()?.sourceUnresolved ?? false)
            }
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        fixture.setSnapshot(try makeSnapshot(baseline))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertTrue(try XCTUnwrap(readRecord(in: directory)).sourceUnresolved)
        controller?.systemWillSleep()
        controller?.systemDidWake()
        controller?.displayChanged(.desktopShapeChangedFlag)
        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))

        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.session, original.session)
        XCTAssertEqual(retained.baseline, baseline)
        XCTAssertTrue(retained.canClear)
        XCTAssertFalse(retained.sourceUnresolved)
        XCTAssertEqual(unresolvedAtRestoreWrite.wait(), true)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        controller = nil
    }

    func testSleepGateCancelsStartupAndRetryBeforeOriginWriter() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let writer: OriginWriter = { origins, option in
            let call = fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
            if option == .forAppOnly && call.index == 1 { throw FixtureError.injected }
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)

        let startupGate = fixture.blockSnapshotRead(after: 2)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        let startupEntered = startupGate.waitUntilEntered()
        XCTAssertTrue(startupEntered)
        controller?.systemWillSleep()
        startupGate.release()
        XCTAssertTrue(statuses.wait(for: .unsupported("系统睡眠中，等待唤醒")))
        XCTAssertTrue(fixture.writes.isEmpty)
        let prepared = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(prepared.phase, .owned)
        XCTAssertEqual(prepared.baseline, baseline)
        XCTAssertEqual(prepared.applied, baseline)
        XCTAssertFalse(prepared.layoutPending)
        XCTAssertFalse(prepared.sourceUnresolved)

        controller?.systemDidWake()
        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])

        let writesBeforeRetrySleep = fixture.writes
        let retryGate = fixture.blockSnapshotRead(after: 3)
        controller?.retryApplication()
        let retryEntered = retryGate.waitUntilEntered()
        XCTAssertTrue(retryEntered)
        controller?.systemWillSleep()
        retryGate.release()
        XCTAssertTrue(statuses.wait(for: .unsupported("系统睡眠中，等待唤醒"), count: 2))
        XCTAssertEqual(fixture.writes, writesBeforeRetrySleep)

        controller?.systemDidWake()
        XCTAssertTrue(statuses.wait(for: .applied))
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false, true])
        controller = nil
    }

    func testQuitDuringSleepDoesNotRestoreAndCanRetryAfterWake() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        controller?.systemWillSleep()
        XCTAssertTrue(statuses.wait(for: .unsupported("系统睡眠中，等待唤醒")))
        let firstQuit = CompletionRecorder()
        controller?.quitApplication { firstQuit.finish($0) }
        XCTAssertEqual(firstQuit.wait(), false)
        XCTAssertTrue(statuses.wait(for: .quitFailed))
        let interrupted = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(interrupted.session, original.session)
        XCTAssertEqual(interrupted.baseline, baseline)
        XCTAssertFalse(interrupted.canClear)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])
        XCTAssertEqual(try fixture.snapshot().layout(), target)

        controller?.systemDidWake()
        let retry = CompletionRecorder()
        controller?.quitApplication { retry.finish($0) }
        XCTAssertEqual(retry.wait(), true)
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(restored.session, original.session)
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertTrue(restored.canClear)
        let writes = fixture.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map(\.appOnly), [true, false])
        XCTAssertEqual(writes[1].origins, [
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ])
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        controller = nil
    }

    func testRepeatedEventsDoNotRewriteAndShutdownDoesNotReapply() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let restoreEntered = DispatchSemaphore(value: 0)
        let continueRestore = DispatchSemaphore(value: 0)
        let writer: OriginWriter = { origins, option in
            let call = fixture.recordWrite(origins, option: option)
            if call.index == 2 {
                restoreEntered.signal()
                guard continueRestore.wait(timeout: .now() + 4) == .success else { throw FixtureError.timeout }
            }
            fixture.applyOrigins(origins)
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait { $0 == .applied })

        controller?.displayChanged(.addFlag)
        controller?.displayChanged(.addFlag)
        controller?.displayChanged(.addFlag)
        XCTAssertTrue(statuses.wait(for: .applied, count: 2))
        XCTAssertEqual(fixture.writes.count, 1)

        let completion = CompletionRecorder()
        controller?.quitApplication { completion.finish($0) }
        let entered = restoreEntered.wait(timeout: .now() + 2)
        if entered == .success { controller?.displayChanged(.addFlag) }
        continueRestore.signal()
        XCTAssertEqual(entered, .success)
        XCTAssertEqual(completion.wait(), true)
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertFalse(fixture.writes[1].appOnly)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        controller = nil
    }

    func testQuitDuringInitialControlDrainsQueuedEventsWithoutStaleReapplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let writerEntered = DispatchSemaphore(value: 0)
        let continueInitialWrite = DispatchSemaphore(value: 0)
        defer { continueInitialWrite.signal() }
        let writer: OriginWriter = { origins, option in
            let call = fixture.recordWrite(origins, option: option)
            if call.index == 1 && option == .forAppOnly {
                writerEntered.signal()
                guard continueInitialWrite.wait(timeout: .now() + 4) == .success else {
                    throw FixtureError.timeout
                }
            }
            fixture.applyOrigins(origins)
        }
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture, writer: writer)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        let entered = writerEntered.wait(timeout: .now() + 2)
        XCTAssertEqual(entered, .success)
        let completion = CompletionRecorder()
        controller?.quitApplication { completion.finish($0) }
        controller?.displayChanged(.addFlag)
        controller?.displayChanged(.desktopShapeChangedFlag)
        controller?.systemDidWake()
        controller?.displayChanged(.enabledFlag)
        controller?.systemDidWake()
        continueInitialWrite.signal()

        XCTAssertEqual(completion.wait(), true)
        let restored = try XCTUnwrap(readRecord(in: directory))
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(restored.phase, .restored)
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        XCTAssertEqual(fixture.writes[1].origins, [
            80: DisplayOrigin(x: 0, y: 0),
            40: DisplayOrigin(x: 1728, y: 0)
        ])
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)

        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        XCTAssertEqual(try XCTUnwrap(readRecord(in: directory)).baseline, baseline)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)
        controller = nil
    }

    private typealias OriginWriter = @Sendable ([UInt32: DisplayOrigin], CGConfigureOption) throws -> Void

    private enum FixtureError: Error {
        case injected
        case timeout
    }

    private struct UnknownConfigurationSession {
        let directory: URL
        let fixture: ControllerFixture
        let statuses: StatusRecorder
        var controller: PrimaryController?
        let original: RecoveryRecord
        let unresolved: RecoveryRecord
        let current: DisplayLayout
        let target: DisplayLayout
    }

    private struct WriteCall: Equatable {
        let index: Int
        let origins: [UInt32: DisplayOrigin]
        let appOnly: Bool
    }

    private final class ControllerFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Snapshot
        private var snapshotSequence: [Snapshot] = []
        private var snapshotReadCountdown: Int?
        private var snapshotReadGate: SnapshotReadGate?
        private var lid = "开盖"
        private var recordedWrites: [WriteCall] = []

        init(snapshot: Snapshot) { current = snapshot }

        var writes: [WriteCall] { lock.withLock { recordedWrites } }

        func snapshot() -> Snapshot {
            var gate: SnapshotReadGate?
            let result = lock.withLock {
                let snapshot = snapshotSequence.isEmpty ? current : snapshotSequence.removeFirst()
                if let countdown = snapshotReadCountdown {
                    if countdown == 1 {
                        gate = snapshotReadGate
                        snapshotReadCountdown = nil
                        snapshotReadGate = nil
                    } else {
                        snapshotReadCountdown = countdown - 1
                    }
                }
                return snapshot
            }
            gate?.pause()
            return result
        }

        func setSnapshot(_ snapshot: Snapshot) {
            lock.withLock {
                current = snapshot
                snapshotSequence = []
            }
        }

        func setSnapshotSequence(_ snapshots: [Snapshot]) { lock.withLock { snapshotSequence = snapshots } }

        func blockSnapshotRead(after count: Int) -> SnapshotReadGate {
            let gate = SnapshotReadGate()
            lock.withLock {
                snapshotReadCountdown = count
                snapshotReadGate = gate
            }
            return gate
        }

        func setLid(_ state: String) { lock.withLock { lid = state } }

        func lidState() -> String { lock.withLock { lid } }

        @discardableResult
        func recordWrite(_ origins: [UInt32: DisplayOrigin], option: CGConfigureOption) -> WriteCall {
            lock.withLock {
                let call = WriteCall(index: recordedWrites.count + 1, origins: origins, appOnly: option == .forAppOnly)
                recordedWrites.append(call)
                return call
            }
        }

        func applyOrigins(_ origins: [UInt32: DisplayOrigin]) {
            lock.withLock {
                current = Snapshot(displays: current.displays.map { display in
                    guard let origin = origins[display.id] else { return display }
                    return DisplayState(
                        id: display.id,
                        identity: display.identity,
                        identityUUID: display.identityUUID,
                        isOnline: display.isOnline,
                        isActive: display.isActive,
                        isMain: origin.x == 0 && origin.y == 0,
                        isMirrored: display.isMirrored,
                        originX: CGFloat(origin.x),
                        originY: CGFloat(origin.y),
                        width: display.width,
                        height: display.height,
                        rotation: display.rotation,
                        mode: display.mode
                    )
                })
            }
        }
    }

    private final class StatusRecorder: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [PrimarySessionStatus] = []

        var count: Int {
            condition.lock()
            defer { condition.unlock() }
            return values.count
        }

        func append(_ status: PrimarySessionStatus) {
            condition.lock()
            values.append(status)
            condition.broadcast()
            condition.unlock()
        }

        func wait(
            for predicate: (PrimarySessionStatus) -> Bool,
            count: Int = 1,
            timeout: TimeInterval = 4
        ) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while values.filter(predicate).count < count {
                if !condition.wait(until: deadline) { return false }
            }
            return true
        }

        func wait(for status: PrimarySessionStatus, count: Int = 1, timeout: TimeInterval = 4) -> Bool {
            wait(for: { $0 == status }, count: count, timeout: timeout)
        }
    }

    private final class CompletionRecorder: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Bool?

        func finish(_ value: Bool) {
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }

        func wait(timeout: TimeInterval = 4) -> Bool? {
            let deadline = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while result == nil {
                if !condition.wait(until: deadline) { return nil }
            }
            return result
        }
    }

    private final class SnapshotReadGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let releaseRead = DispatchSemaphore(value: 0)

        func pause() {
            entered.signal()
            _ = releaseRead.wait(timeout: .now() + 4)
        }

        func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
            entered.wait(timeout: .now() + timeout) == .success
        }

        func release() { releaseRead.signal() }
    }

    private func makeController(
        directory: URL,
        fixture: ControllerFixture,
        writer: OriginWriter? = nil
    ) throws -> PrimaryController {
        let selectedWriter = writer ?? { origins, option in
            fixture.recordWrite(origins, option: option)
            fixture.applyOrigins(origins)
        }
        return try PrimaryController(
            directory: directory,
            snapshotReader: { fixture.snapshot() },
            originWriter: selectedWriter,
            lidReader: { fixture.lidState() }
        )
    }

    private func layout(mainExternal: Bool = false, externalIdentity: UUID? = nil) throws -> DisplayLayout {
        let external = externalIdentity ?? externalID
        return try DisplayLayout(
            main: mainExternal ? external : internalID,
            origins: [
                internalID: DisplayOrigin(x: mainExternal ? -1728 : 0, y: 0),
                external: DisplayOrigin(x: mainExternal ? 0 : 1728, y: 0)
            ]
        )
    }

    private func makeSnapshot(
        _ layout: DisplayLayout,
        includeInternal: Bool = true,
        includeExternal: Bool = true,
        mirrored: Bool = false,
        externalIdentity: UUID? = nil
    ) throws -> Snapshot {
        let external = externalIdentity ?? externalID
        var displays: [DisplayState] = []
        if includeInternal {
            displays.append(makeDisplay(id: 80, identity: .builtIn, uuid: internalID, layout: layout))
        }
        if includeExternal {
            displays.append(makeDisplay(
                id: 40,
                identity: .physical,
                uuid: external,
                layout: layout,
                mirrored: mirrored
            ))
        }
        return Snapshot(displays: displays)
    }

    private func makeDisplay(
        id: UInt32,
        identity: DisplayIdentity,
        uuid: UUID,
        layout: DisplayLayout,
        mirrored: Bool = false
    ) -> DisplayState {
        let origin = layout.origins[uuid] ?? DisplayOrigin(x: 0, y: 0)
        return DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: true,
            isActive: true,
            isMain: layout.main == uuid,
            isMirrored: mirrored,
            originX: CGFloat(origin.x),
            originY: CGFloat(origin.y),
            width: 1920,
            height: 1080,
            rotation: 0,
            mode: DisplayModeState(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioDisplayModeID: 1)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExtilumeNativeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func readRecord(in directory: URL) throws -> RecoveryRecord? {
        try RecoveryStore(directory: directory).load()
    }

    private func seedOwnedRecord(in directory: URL) throws -> RecoveryRecord {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        return try store.apply(RecoveryRecord(baseline: baseline, target: target)) {
            (target, nil)
        }
    }

    private func selectedLayoutC() throws -> DisplayLayout {
        try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
    }

    private func makeUnknownConfigurationSession() throws -> UnknownConfigurationSession {
        let directory = try makeTemporaryDirectory()
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let current = try selectedLayoutC()
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline))
        let statuses = StatusRecorder()
        let controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .applied))
        let original = try XCTUnwrap(readRecord(in: directory))

        fixture.setSnapshot(try makeSnapshot(current))
        controller?.displayChanged(.desktopShapeChangedFlag)
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        let unresolved = try XCTUnwrap(readRecord(in: directory))

        return UnknownConfigurationSession(
            directory: directory,
            fixture: fixture,
            statuses: statuses,
            controller: controller,
            original: original,
            unresolved: unresolved,
            current: current,
            target: target
        )
    }

    private func assertConfirmationRejected(with snapshot: Snapshot) throws {
        var session = try makeUnknownConfigurationSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        session.fixture.setSnapshot(snapshot)

        session.controller?.confirmCurrentConfiguration()

        XCTAssertTrue(session.statuses.wait(for: .confirmationFailed))
        XCTAssertEqual(try XCTUnwrap(readRecord(in: session.directory)), session.unresolved)
        XCTAssertEqual(session.fixture.writes.map(\.appOnly), [true])
        session.controller = nil
    }
}
