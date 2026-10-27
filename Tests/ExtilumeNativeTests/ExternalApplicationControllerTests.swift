import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalApplicationControllerTests: XCTestCase {
    final class Fixture: @unchecked Sendable {
        let directory: URL
        let internalID = UUID()
        let externalID = UUID()
        let token = NSObject()
        let lock = NSLock()
        var enabled = true
        var staged = true
        var current: Snapshot!
        var preDisable: DisplayLayout?
        var writes = 0
        var statuses: [PrimarySessionStatus] = []
        var lid = true
        var failRecovery = false
        var failDisable = false
        var originalMissing = false
        var zeroWhileDisabled = false
        var afterConfigure: (@Sendable () -> Void)?
        var blockNextCommit = false
        let commitStarted = DispatchSemaphore(value: 0)
        let continueCommit = DispatchSemaphore(value: 0)
        let readStarted = DispatchSemaphore(value: 0)
        let continueRead = DispatchSemaphore(value: 0)
        var blockNextRead = false
        var blockFinalInputRead = false
        var disabledReads = 0
        var identity: ExternalDisplayIdentity {
            ExternalDisplayIdentity(uuid: externalID, registryPath: "IOService:/fixture/external", edidUUID: "fixture",
                                    bootSession: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, registryEntryID: 7)
        }
        var baseline: DisplayLayout {
            try! DisplayLayout(main: externalID, origins: [internalID: DisplayOrigin(x: -100, y: 0), externalID: DisplayOrigin(x: 0, y: 0)])
        }
        var fullInternal: DisplayLayout { try! layoutByMakingMain(baseline, target: internalID) }
        var onlyInternal: DisplayLayout { try! DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)]) }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            current = snapshot(baseline)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func snapshot(_ layout: DisplayLayout) -> Snapshot {
            Snapshot(displays: layout.origins.map { uuid, position in
                DisplayState(id: uuid == internalID ? 1 : 2, identity: uuid == internalID ? .builtIn : .physical,
                    identityUUID: uuid, isOnline: true, isActive: true, isMain: uuid == layout.main, isMirrored: false,
                    originX: CGFloat(position.x), originY: CGFloat(position.y), width: 100, height: 100, rotation: 0,
                    mode: DisplayModeState(width: 100, height: 100, pixelWidth: 100, pixelHeight: 100, refreshRate: 60, ioDisplayModeID: 1))
            }.sorted { $0.id < $1.id })
        }
        func readSnapshot() -> Snapshot {
            let block = lock.withLock {
                if !enabled { disabledReads += 1 }
                let finalInputRead = blockFinalInputRead && !enabled && disabledReads == 2
                let result = blockNextRead || finalInputRead
                blockNextRead = false
                if finalInputRead { blockFinalInputRead = false }
                return result
            }
            if block { readStarted.signal(); _ = continueRead.wait(timeout: .now() + 5) }
            return lock.withLock { current }
        }
        func readExternal() -> ExternalDisplayState {
            lock.withLock { ExternalDisplayState(id: 2, identity: identity, isOnline: true, isActive: enabled) }
        }
        func seedHeld() throws {
            var record = try RecoveryRecord(baseline: baseline, target: fullInternal,
                externalDisplay: ExternalDisplayResponsibility(identity: identity, numericIDHint: 2, baseline: true, applied: false))
            try record.markApplying()
            try record.confirmApplied(onlyInternal, internalEnabled: true, externalEnabled: false)
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership(); try store.save(record)
            lock.withLock { enabled = false; current = snapshot(onlyInternal) }
        }
        func controller(recoveryStore: RecoveryStore? = nil) throws -> ExternalApplicationController {
            try ExternalApplicationController(directory: directory, recoveryStore: recoveryStore, verificationFactory: { directory, store, check, native in
                try ExternalDisplayVerification(directory: directory, recoveryStore: store,
                    snapshot: { self.readSnapshot() }, topology: { self.readSnapshot() },
                    external: { _, _ in
                        if self.lock.withLock({ self.originalMissing || (self.zeroWhileDisabled && !self.enabled) }) {
                            throw RecoveryError.identityConflict
                        }
                        return self.readExternal()
                    }, recoveryObservation: { _, _ in
                        if self.lock.withLock({ self.originalMissing }) { throw RecoveryError.identityConflict }
                        if self.lock.withLock({ self.zeroWhileDisabled && !self.enabled }) {
                            return .connection(ExternalConnectionEvidence(id: 2,
                                observedUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                                registryPath: self.identity.registryPath, edidUUID: self.identity.edidUUID,
                                bootSession: self.identity.bootSession, registryEntryID: self.identity.registryEntryID,
                                isBuiltin: false, isOnline: false, isActive: false, matchingSlotCount: 1,
                                allSlotsExcludeOriginalUUID: true, registryIsHDMI: true, registryClassMatches: true))
                        }
                        return .identified(self.readExternal())
                    }, capture: { _ in self.readExternal() },
                    lidIsOpen: { self.lock.withLock { self.lid } }, transaction: {
                        DisplayEnableTransaction(configure: { _, _, value in
                            self.lock.withLock { self.staged = value }
                            self.lock.withLock { self.afterConfigure }?()
                            return .success
                        }, begin: { pointer in
                            pointer.pointee = unsafeBitCast(Unmanaged.passUnretained(self.token).toOpaque(), to: CGDisplayConfigRef.self)
                            return .success
                        }, complete: { _, _ in
                            let block = self.lock.withLock { let result = self.blockNextCommit; self.blockNextCommit = false; return result }
                            if block { self.commitStarted.signal(); _ = self.continueCommit.wait(timeout: .now() + 5) }
                            return self.lock.withLock {
                                if (self.staged && self.failRecovery) || (!self.staged && self.failDisable) { return .failure }
                                if !self.staged {
                                    self.preDisable = try? layoutByMakingMain(self.current.layout(), target: self.internalID)
                                }
                                self.writes += 1; self.enabled = self.staged
                                self.current = self.snapshot(self.enabled ? (self.preDisable ?? self.fullInternal) : self.onlyInternal)
                                return .success
                            }
                        }, cancel: { _ in .success }, origin: { _, _, _, _ in .success })
                    }, writeOrigins: { origins, validate in
                        try validate()
                        let positions = Dictionary(uniqueKeysWithValues: origins.map { id, origin in
                            (id == 1 ? self.internalID : self.externalID, origin)
                        })
                        guard let main = positions.first(where: { $0.value == DisplayOrigin(x: 0, y: 0) })?.key else {
                            throw RecoveryError.invalidRecord
                        }
                        let restored = try DisplayLayout(main: main, origins: positions)
                        self.lock.withLock { self.writes += 1; self.current = self.snapshot(restored) }
                    }, nativeCall: native, checkAccess: check)
            })
        }
        func start(_ controller: ExternalApplicationController, recoveryOnly: Bool = false) {
            controller.startApplication(registerEvents: false, recoveryOnly: recoveryOnly) { value in
                self.lock.withLock { self.statuses.append(value) }
            }
        }
        func waitFor(_ value: PrimarySessionStatus, count: Int = 1) async throws {
            for _ in 0..<500 {
                if lock.withLock({ statuses.filter { $0 == value }.count >= count }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("status not observed: \(value)")
        }
        var writeCount: Int { lock.withLock { writes } }
        func record() throws -> RecoveryRecord { try XCTUnwrap(RecoveryStore(directory: directory).load()) }
        func systemEnablesOriginal() { lock.withLock { enabled = true; current = snapshot(fullInternal) } }
    }

    func testRestartHoldsThenExplicitRestoreNeverRedisablesOnEvent() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller()
        fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        XCTAssertEqual(fixture.writeCount, 0)
        controller.recoverApplication()
        try await fixture.waitFor(.manualConfiguration)
        let restoredWrites = fixture.writeCount
        controller.displayChanged()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(fixture.writeCount, restoredWrites)
        XCTAssertTrue(try fixture.record().canClear)
        controller.retryApplication()
        try await fixture.waitFor(.applied, count: 2)
        XCTAssertEqual(try fixture.record().baseline, fixture.baseline)
    }

    func testWakeRediablesOnlyKnownTargetAndPreservesC() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); controller.setAutomaticReapplicationAllowed(true)
        fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.systemEnablesOriginal(); controller.didWake()
        try await fixture.waitFor(.applied, count: 2)
        XCTAssertEqual(fixture.writeCount, 1)
        XCTAssertEqual(try fixture.record().baseline, fixture.baseline)
        XCTAssertFalse(fixture.readExternal().isEnabled)
    }

    func testUnknownEnabledCallbackCannotAuthorizeRediabling() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.systemEnablesOriginal(); controller.displayChanged()
        try await fixture.waitFor(.unconfirmed)
        XCTAssertEqual(fixture.writeCount, 0)
        XCTAssertTrue(try fixture.record().sourceUnresolved)
        controller.didWake()
        try await fixture.waitFor(.recoveryIncomplete)
        XCTAssertEqual(fixture.writeCount, 0)
    }

    func testSleepRevokesBlockedApplyAndNoConcurrentQuitWrite() async throws {
        let fixture = try Fixture()
        fixture.lock.withLock { fixture.blockNextRead = true }
        let controller = try fixture.controller(); fixture.start(controller)
        XCTAssertEqual(fixture.readStarted.wait(timeout: .now() + 3), .success)
        controller.willSleep(); controller.didPrepareForSleep(true)
        fixture.continueRead.signal()
        try await fixture.waitFor(.recoveryIncomplete)
        XCTAssertEqual(fixture.writeCount, 0)
        let completed = expectation(description: "quit fails during sleep")
        controller.quitApplication { success in XCTAssertFalse(success); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(fixture.writeCount, 0)
    }

    func testQuitWaitsForRestorationAndFailureKeepsRecordForRetry() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.lock.withLock { fixture.failRecovery = true }
        let failed = expectation(description: "quit refused")
        controller.quitApplication { success in XCTAssertFalse(success); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(try fixture.record().requiresRecovery)
        fixture.lock.withLock { fixture.failRecovery = false }
        let restored = expectation(description: "quit restored")
        controller.quitApplication { success in XCTAssertTrue(success); restored.fulfill() }
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertTrue(try fixture.record().canClear)
    }

    func testUnknownAndWakeInSameDebounceCannotUpgradeSource() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); controller.setAutomaticReapplicationAllowed(true)
        fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.systemEnablesOriginal(); controller.displayChanged(); controller.didWake()
        try await fixture.waitFor(.unconfirmed)
        XCTAssertEqual(fixture.writeCount, 0)
        XCTAssertTrue(try fixture.record().sourceUnresolved)
    }

    func testDefaultRecoveryGateNeverStartsNewDisableOnWake() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.systemEnablesOriginal(); controller.didWake()
        try await fixture.waitFor(.unconfirmed)
        XCTAssertEqual(fixture.writeCount, 0)
    }

    func testSleepWakeAcrossBlockedReadbackCannotCommitOldGeneration() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); controller.setAutomaticReapplicationAllowed(true)
        fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.systemEnablesOriginal()
        fixture.lock.withLock { fixture.blockNextRead = true }
        controller.didWake()
        XCTAssertEqual(fixture.readStarted.wait(timeout: .now() + 3), .success)
        controller.willSleep(); controller.didPrepareForSleep(true); controller.didWake()
        fixture.continueRead.signal()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.writeCount, 0)
        try await fixture.waitFor(.applied, count: 2)
        XCTAssertEqual(fixture.writeCount, 1)
    }

    func testConfirmUserCCancelsPendingWakeAndCanRecoverAfterFailedRestore() async throws {
        for failRestoreFirst in [false, true] {
            let fixture = try Fixture(); try fixture.seedHeld()
            let controller = try fixture.controller(); controller.setAutomaticReapplicationAllowed(true)
            fixture.start(controller, recoveryOnly: true)
            try await fixture.waitFor(.applied)
            let userC = try DisplayLayout(main: fixture.internalID, origins: [
                fixture.internalID: DisplayOrigin(x: 0, y: 0), fixture.externalID: DisplayOrigin(x: 250, y: 20)
            ])
            fixture.lock.withLock { fixture.enabled = true; fixture.current = fixture.snapshot(userC) }
            if failRestoreFirst {
                controller.displayChanged(); try await fixture.waitFor(.unconfirmed)
                controller.recoverApplication(); try await fixture.waitFor(.unconfirmed, count: 2)
                XCTAssertEqual(try fixture.record().phase, .restoring)
            } else { controller.didWake() }
            controller.confirmCurrentConfiguration(); try await fixture.waitFor(.manualConfiguration)
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertEqual(fixture.writeCount, 0)
            XCTAssertEqual(try fixture.record().baseline, userC)
            controller.recoverApplication(); try await fixture.waitFor(.manualConfiguration, count: 2)
            XCTAssertTrue(try fixture.record().canClear)
            XCTAssertEqual(fixture.writeCount, 0)
        }
    }

    @MainActor
    func testCoordinatorKeepsConfirmationReachableAfterUnresolvedRecoveryFailure() async throws {
        final class Preferences: DisplayModePreferenceStoring {
            var selectedMode: DisplayApplicationMode? = .internalOnly
            var internalControlLocked = false
            var externalHandoffRequested = true
            func select(_ mode: DisplayApplicationMode) throws { selectedMode = mode }
            func lockInternalControl() throws { internalControlLocked = true }
            func setExternalHandoffRequested(_ requested: Bool) throws { externalHandoffRequested = requested }
        }
        let fixture = try Fixture(); try fixture.seedHeld()
        let preferences = Preferences()
        var owner: ExternalApplicationController?
        let coordinator = try DisplayModeCoordinator(directory: fixture.directory, preferences: preferences,
            availableModes: [.externalPrimary, .internalOnly]) { _, _, store in
                let controller = try fixture.controller(recoveryStore: store)
                owner = controller
                return controller
            }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { status in
            fixture.lock.withLock { fixture.statuses.append(status) }
        }
        try await fixture.waitFor(.applied)
        let userC = try DisplayLayout(main: fixture.internalID, origins: [
            fixture.internalID: DisplayOrigin(x: 0, y: 0), fixture.externalID: DisplayOrigin(x: 250, y: 20)
        ])
        fixture.lock.withLock { fixture.enabled = true; fixture.current = fixture.snapshot(userC) }
        owner?.displayChanged()
        try await fixture.waitFor(.unconfirmed)
        coordinator.recoverApplication()
        try await fixture.waitFor(.unconfirmed, count: 2)
        XCTAssertEqual(try fixture.record().phase, .restoring)
        coordinator.confirmCurrentConfiguration()
        try await fixture.waitFor(.manualConfiguration)
        XCTAssertEqual(try fixture.record().baseline, userC)
        let quit = expectation(description: "confirmed layout can quit")
        coordinator.quitApplication { success in XCTAssertTrue(success); quit.fulfill() }
        await fulfillment(of: [quit], timeout: 3)
        XCTAssertTrue(try fixture.record().canClear)
        XCTAssertEqual(fixture.writeCount, 0)
    }

    func testRestoredRecordCanConfirmNewCBeforeNextHandoffOrQuit() async throws {
        for quitting in [false, true] {
            let fixture = try Fixture(); try fixture.seedHeld()
            let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
            try await fixture.waitFor(.applied)
            controller.recoverApplication(); try await fixture.waitFor(.manualConfiguration)
            XCTAssertTrue(try fixture.record().canClear)
            let userC = try DisplayLayout(main: fixture.internalID, origins: [
                fixture.internalID: DisplayOrigin(x: 0, y: 0), fixture.externalID: DisplayOrigin(x: 250, y: 20)
            ])
            fixture.lock.withLock { fixture.current = fixture.snapshot(userC) }
            let writesBefore = fixture.writeCount
            if quitting {
                let refused = expectation(description: "new layout needs confirmation before quit")
                controller.quitApplication { success in XCTAssertFalse(success); refused.fulfill() }
                await fulfillment(of: [refused], timeout: 3)
                try await fixture.waitFor(.quitFailed)
            } else {
                controller.retryApplication()
                try await fixture.waitFor(.unconfirmed)
            }
            XCTAssertEqual(fixture.writeCount, writesBefore)
            controller.confirmCurrentConfiguration()
            try await fixture.waitFor(.manualConfiguration, count: 2)
            XCTAssertEqual(try fixture.record().baseline, userC)
            if quitting {
                let finished = expectation(description: "new layout confirmed then quit")
                controller.quitApplication { success in XCTAssertTrue(success); finished.fulfill() }
                await fulfillment(of: [finished], timeout: 3)
                XCTAssertEqual(fixture.writeCount, writesBefore)
            } else {
                controller.retryApplication(); try await fixture.waitFor(.applied, count: 2)
                controller.recoverApplication(); try await fixture.waitFor(.manualConfiguration, count: 3)
            }
            XCTAssertTrue(try fixture.record().canClear)
            XCTAssertEqual(try fixture.record().baseline, userC)
            XCTAssertEqual(try fixture.readSnapshot().layout(), userC)
        }
    }

    func testMissingOriginalNeverControlsReplacementOrClearsResponsibility() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        let baseline = try fixture.record().baseline
        fixture.lock.withLock { fixture.originalMissing = true }
        controller.displayChanged(); try await fixture.waitFor(.recoveryIncomplete)
        XCTAssertEqual(fixture.writeCount, 0)
        XCTAssertTrue(try fixture.record().requiresRecovery)
        XCTAssertEqual(try fixture.record().baseline, baseline)
    }

    func testInFlightCommitReturnsBeforeQuitCanRestoreAndComplete() async throws {
        let fixture = try Fixture(), controller = try fixture.controller()
        fixture.lock.withLock { fixture.blockNextCommit = true }
        fixture.start(controller)
        XCTAssertEqual(fixture.commitStarted.wait(timeout: .now() + 3), .success)
        let stopped = expectation(description: "commit then restore before quit")
        let completionLock = NSLock()
        nonisolated(unsafe) var completed = false
        controller.quitApplication { success in
            XCTAssertTrue(success)
            completionLock.withLock { completed = true }
            stopped.fulfill()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(completionLock.withLock { completed })
        fixture.continueCommit.signal()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(try fixture.record().canClear)
        XCTAssertEqual(fixture.writeCount, 3)
    }

    final class Input: ExternalDisplayInputControlling, @unchecked Sendable {
        let fixture: Fixture
        let lock = NSLock()
        var sends = 0
        var reads = 0
        var fail = false
        init(_ fixture: Fixture) { self.fixture = fixture }
        func availability(for target: ExternalDisplayIdentity) -> ExternalDisplayInputAvailability {
            target == fixture.identity ? .available : .unavailable(.identityMismatch)
        }
        func readCapabilities(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> ExternalDisplayInputCapabilities {
            XCTAssertTrue(fixture.readExternal().isEnabled)
            lock.withLock { reads += 1 }
            return ExternalDisplayInputCapabilities(target: target, inputValues: [0x11])
        }
        func sendOnce(_ configuration: ExternalDisplayInputConfiguration, capabilities: ExternalDisplayInputCapabilities,
                      deadlineNanoseconds: UInt64) throws {
            XCTAssertFalse(fixture.readExternal().isEnabled)
            let shouldFail = lock.withLock { sends += 1; return fail }
            if shouldFail { throw ExternalDisplayInputFailure.readbackUnavailable }
        }
        var sendCount: Int { lock.withLock { sends } }
        var readCount: Int { lock.withLock { reads } }
        var session: ExternalAutomaticInputSession {
            ExternalAutomaticInputSession(configuration: ExternalDisplayInputConfiguration(target: fixture.identity,
                pcInput: 0x11, automaticEnabled: true), capabilities: ExternalDisplayInputCapabilities(target: fixture.identity,
                    inputValues: [0x11]), controller: self)
        }
    }

    func testFinalReadbackRevocationPreventsInputWrite() async throws {
        for quitting in [true, false] {
            let fixture = try Fixture(), input = Input(fixture), controller = try fixture.controller()
            fixture.lock.withLock { fixture.blockFinalInputRead = true }
            controller.configureAutomaticInput(input.session, sendOnStart: true)
            fixture.start(controller)
            XCTAssertEqual(fixture.readStarted.wait(timeout: .now() + 3), .success)
            let ended = expectation(description: "revoked readback returns")
            if quitting {
                controller.quitApplication { success in XCTAssertTrue(success); ended.fulfill() }
            } else {
                controller.willSleep()
                controller.didPrepareForSleep(true)
            }
            fixture.continueRead.signal()
            if quitting { await fulfillment(of: [ended], timeout: 3) }
            else {
                try await fixture.waitFor(.recoveryIncomplete)
                controller.didWake()
                controller.recoverApplication()
                try await fixture.waitFor(.manualConfiguration)
                ended.fulfill()
                await fulfillment(of: [ended], timeout: 3)
            }
            XCTAssertEqual(input.sendCount, 0)
            XCTAssertTrue(try fixture.record().canClear)
        }
    }

    func testAutomaticInputOnlyFollowsExplicitSuccessfulEntryOnce() async throws {
        let fixture = try Fixture(), input = Input(fixture), controller = try fixture.controller()
        controller.configureAutomaticInput(input.session, sendOnStart: true)
        fixture.start(controller); try await fixture.waitFor(.applied)
        XCTAssertEqual(input.sendCount, 1)
        XCTAssertEqual(input.readCount, 1)
        controller.displayChanged(); controller.didWake()
        try await fixture.waitFor(.applied, count: 2)
        XCTAssertEqual(input.sendCount, 1)
        controller.recoverApplication(); try await fixture.waitFor(.manualConfiguration)
        controller.retryApplication(); try await fixture.waitFor(.applied, count: 3)
        XCTAssertEqual(input.sendCount, 2)
    }

    func testRestartAndDisableFailureNeverSendAutomaticInput() async throws {
        for restarting in [true, false] {
            let fixture = try Fixture()
            if restarting { try fixture.seedHeld() }
            else { fixture.lock.withLock { fixture.failDisable = true } }
            let input = Input(fixture), controller = try fixture.controller()
            controller.configureAutomaticInput(input.session, sendOnStart: !restarting)
            fixture.start(controller, recoveryOnly: restarting)
            try await fixture.waitFor(restarting ? .applied : .recoveryIncomplete)
            XCTAssertEqual(input.sendCount, 0)
            XCTAssertEqual(input.readCount, restarting ? 0 : 1)
        }
    }

    func testInputFailureKeepsHandoffWithoutRetryOrRollback() async throws {
        let fixture = try Fixture(), input = Input(fixture), controller = try fixture.controller()
        input.fail = true
        let result = expectation(description: "input unconfirmed")
        controller.configureAutomaticInput(input.session, sendOnStart: true) { outcome in
            if case .unconfirmed = outcome { result.fulfill() }
            else { XCTFail("must report unconfirmed") }
        }
        fixture.start(controller); try await fixture.waitFor(.applied)
        await fulfillment(of: [result], timeout: 3)
        XCTAssertEqual(input.sendCount, 1)
        XCTAssertFalse(fixture.readExternal().isEnabled)
        XCTAssertTrue(try fixture.record().requiresRecovery)
        XCTAssertEqual(fixture.writeCount, 1)
    }

    private func prepare(_ controller: ExternalApplicationController) async throws -> ExternalConnectionRecoveryConfirmation {
        let result = await withCheckedContinuation { continuation in
            controller.prepareConnectionRecovery { continuation.resume(returning: $0) }
        }
        return try XCTUnwrap(result.get())
    }

    func testZeroUUIDHoldingAndExplicitConnectionRecovery() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        fixture.zeroWhileDisabled = true
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        let before = try fixture.record()
        let confirmation = try await prepare(controller)
        XCTAssertEqual(try fixture.record(), before)
        controller.recoverAfterConfirmingConnection(confirmation)
        try await fixture.waitFor(.manualConfiguration)
        XCTAssertTrue(try fixture.record().canClear)
        XCTAssertEqual(try fixture.readSnapshot().layout(), fixture.baseline)
        let writes = fixture.writeCount
        controller.recoverAfterConfirmingConnection(confirmation)
        try await fixture.waitFor(.recoveryIncomplete)
        XCTAssertEqual(fixture.writeCount, writes)
    }

    func testConnectionConfirmationIsRevokedByLifecycleOrAnotherRequest() async throws {
        for event in 0..<4 {
            let fixture = try Fixture(); try fixture.seedHeld()
            fixture.zeroWhileDisabled = true
            let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
            try await fixture.waitFor(.applied)
            let confirmation = try await prepare(controller)
            switch event {
            case 0: controller.displayChanged()
            case 1: controller.willSleep()
            case 2: controller.didWake()
            default: controller.recoverApplication()
            }
            controller.recoverAfterConfirmingConnection(confirmation)
            _ = await withCheckedContinuation { continuation in
                controller.quitApplication { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(fixture.writeCount, 0)
            XCTAssertTrue(try fixture.record().requiresRecovery)
        }
    }

    func testDisplayChangeDuringPreparationCannotReturnOrdinaryRecoveryOrToken() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        fixture.zeroWhileDisabled = true
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        let before = try fixture.record()
        fixture.lock.withLock { fixture.blockNextRead = true }
        let completed = expectation(description: "stale preparation rejected")
        controller.prepareConnectionRecovery { result in
            if case .success = result { XCTFail("stale preparation must not become an ordinary recovery") }
            completed.fulfill()
        }
        XCTAssertEqual(fixture.readStarted.wait(timeout: .now() + 3), .success)
        controller.displayChanged()
        fixture.continueRead.signal()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(fixture.writeCount, 0)
        XCTAssertEqual(try fixture.record(), before)
    }

    func testConfirmedRecoveryRevocationAfterConfigurePreventsCommit() async throws {
        for sleeping in [false, true] {
            let fixture = try Fixture(); try fixture.seedHeld()
            fixture.zeroWhileDisabled = true
            let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
            try await fixture.waitFor(.applied)
            let confirmation = try await prepare(controller)
            fixture.lock.withLock {
                fixture.afterConfigure = { [weak controller] in
                    if sleeping { controller?.willSleep() }
                    else { controller?.displayChanged() }
                }
            }
            controller.recoverAfterConfirmingConnection(confirmation)
            try await fixture.waitFor(.recoveryIncomplete)
            XCTAssertEqual(fixture.writeCount, 0)
            XCTAssertEqual(try fixture.record().phase, .restoring)
            XCTAssertTrue(try fixture.record().requiresRecovery)
        }
    }

    func testConnectionOnlyHandoffNeverSendsAutomaticInput() async throws {
        let fixture = try Fixture()
        fixture.zeroWhileDisabled = true
        let input = Input(fixture), controller = try fixture.controller()
        controller.configureAutomaticInput(input.session, sendOnStart: true)
        fixture.start(controller)
        try await fixture.waitFor(.applied)
        XCTAssertEqual(input.sendCount, 0)
        XCTAssertEqual(fixture.writeCount, 1)
        XCTAssertTrue(try fixture.record().requiresRecovery)
    }

    func testClosedLidCompensatesOriginalExternalWithoutInputSourceCommand() async throws {
        let fixture = try Fixture(); try fixture.seedHeld()
        let controller = try fixture.controller(); fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        fixture.lock.withLock { fixture.lid = false }
        controller.displayChanged()
        try await fixture.waitFor(.manualConfiguration)
        XCTAssertTrue(fixture.readExternal().isEnabled)
        XCTAssertTrue(try fixture.record().canClear)
    }
}
