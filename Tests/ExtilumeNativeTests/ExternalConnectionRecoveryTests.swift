import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalConnectionRecoveryTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let store: RecoveryStore
        let internalID = UUID()
        let externalID = UUID()
        let boot = UUID()
        let handle = NSObject()
        var events: [String] = []
        var enabled = false
        var online = false
        var active = false
        var identityAvailable = true
        var wrongIdentity = false
        var lidOpen = true
        var internalMain = true
        var mirrored = false
        var foreign = false
        var completeFails = false
        var afterConfigure: () -> Void = {}
        var baselineAfterEnable = true
        var expectedRestoring: RecoveryRecord?

        var identity: ExternalDisplayIdentity {
            ExternalDisplayIdentity(uuid: externalID, registryPath: "IOService:/test-hdmi", edidUUID: "test-edid",
                                    bootSession: boot, registryEntryID: 7)
        }
        var baseline: DisplayLayout {
            get throws { try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0),
                                                                         internalID: DisplayOrigin(x: -100, y: 0)]) }
        }
        var onlyInternal: DisplayLayout {
            get throws { try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)]) }
        }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            var record = try RecoveryRecord(baseline: baseline, target: layoutByMakingMain(baseline, target: internalID),
                externalDisplay: ExternalDisplayResponsibility(identity: identity, numericIDHint: 2, baseline: true, applied: false))
            try record.markApplying()
            try record.confirmApplied(onlyInternal, internalEnabled: true, externalEnabled: false)
            try store.save(record)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        func evidence(id: UInt32 = 2, path: String? = nil, online: Bool? = nil, active: Bool? = nil) -> ExternalRecoveryObservation {
            .connection(ExternalConnectionEvidence(id: id, observedUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                registryPath: path ?? identity.registryPath, edidUUID: identity.edidUUID, bootSession: boot, registryEntryID: 7,
                isBuiltin: false, isOnline: online ?? self.online, isActive: active ?? self.active,
                matchingSlotCount: 1, allSlotsExcludeOriginalUUID: true, registryIsHDMI: true, registryClassMatches: true))
        }
        func state(id: UInt32 = 2, identity: ExternalDisplayIdentity? = nil) -> ExternalDisplayState {
            ExternalDisplayState(id: id, identity: identity ?? self.identity, isOnline: true, isActive: true)
        }
        func snapshot() throws -> Snapshot {
            let layout = enabled && baselineAfterEnable ? try baseline : try onlyInternal
            let mode = DisplayModeState(width: 100, height: 100, pixelWidth: 100, pixelHeight: 100,
                                        refreshRate: 60, ioDisplayModeID: 1)
            var displays = layout.origins.map { uuid, position in
                DisplayState(id: uuid == internalID ? 1 : 2, identity: uuid == internalID ? .builtIn : .physical,
                    identityUUID: uuid, isOnline: true, isActive: true,
                    isMain: uuid == internalID && !enabled ? internalMain : uuid == layout.main,
                    isMirrored: mirrored, originX: CGFloat(position.x), originY: CGFloat(position.y),
                    width: 100, height: 100, rotation: 0, mode: mode)
            }.sorted { $0.id < $1.id }
            if foreign {
                displays.append(DisplayState(id: 3, identity: .physical, identityUUID: UUID(), isOnline: true,
                    isActive: false, isMain: false, isMirrored: false, originX: 0, originY: 0,
                    width: 100, height: 100, rotation: 0, mode: mode))
            }
            return Snapshot(displays: displays)
        }
        func transaction() -> DisplayEnableTransaction {
            DisplayEnableTransaction(configure: { _, id, value in
                self.events.append("configure:\(id):\(value)"); self.afterConfigure(); return .success
            }, begin: { pointer in
                self.events.append("begin")
                pointer.pointee = unsafeBitCast(Unmanaged.passUnretained(self.handle).toOpaque(), to: CGDisplayConfigRef.self)
                return .success
            }, complete: { _, _ in
                self.events.append("complete")
                if self.completeFails { return .failure }
                self.enabled = true
                return .success
            }, cancel: { _ in self.events.append("cancel"); return .success },
               origin: { _, _, _, _ in XCTFail("unexpected native origin"); return .failure })
        }
        func verifier() throws -> ExternalDisplayVerification {
            try ExternalDisplayVerification(directory: directory, recoveryStore: store,
                snapshot: { try self.snapshot() }, topology: { try self.snapshot() },
                external: { _, _ in
                    guard self.enabled, self.identityAvailable, !self.wrongIdentity else { throw RecoveryError.identityConflict }
                    return self.state()
                }, recoveryObservation: { _, _ in
                    self.enabled && self.identityAvailable && !self.wrongIdentity ? .identified(self.state()) : self.evidence()
                }, lidIsOpen: { self.lidOpen }, transaction: { self.transaction() },
                writeOrigins: { _, validate in try validate(); XCTFail("unexpected layout write") },
                nativeCall: { call in
                    XCTAssertEqual(try self.store.load(), self.expectedRestoring)
                    return call()
                })
        }
        func prepareRestoring() throws {
            var record = try XCTUnwrap(store.load())
            record.beginRestoration()
            expectedRestoring = record
        }
    }

    func testConfirmationIsReadOnlyRequiredAndSuccessfulRestoreUsesDurableRecord() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let verifier = try f.verifier(), initial = try XCTUnwrap(f.store.load())
        XCTAssertFalse(try verifier.hasCompleteIdentityForInput())
        let token = try XCTUnwrap(verifier.prepareConnectionRecovery())
        XCTAssertEqual(try f.store.load(), initial)
        XCTAssertThrowsError(try verifier.restore()) {
            XCTAssertEqual($0 as? ExternalConnectionRecoveryError, .confirmationRequired)
        }
        XCTAssertEqual(try f.store.load(), initial)
        XCTAssertTrue(f.events.isEmpty)
        try f.prepareRestoring()
        try verifier.restore(confirmation: token)
        XCTAssertEqual(f.events, ["begin", "configure:2:true", "complete"])
        let restored = try XCTUnwrap(f.store.load())
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(restored.baseline, try f.baseline)
        XCTAssertTrue(try verifier.hasCompleteIdentityForInput())
        XCTAssertThrowsError(try verifier.restore(confirmation: token))
    }

    func testCancelledChangedAndReplayedTokensNeverWrite() throws {
        for scenario in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }
            let verifier = try f.verifier(), token = try XCTUnwrap(verifier.prepareConnectionRecovery())
            if scenario == 0 { token.cancel() }
            if scenario == 1 {
                var changed = try XCTUnwrap(f.store.load()); changed.beginRestoration(); try f.store.save(changed)
            }
            if scenario == 2 { XCTAssertTrue(token.consume(for: try XCTUnwrap(f.store.load()))) }
            let current = try f.store.load()
            XCTAssertThrowsError(try verifier.restore(confirmation: token))
            XCTAssertEqual(try f.store.load(), current)
            XCTAssertTrue(f.events.isEmpty)
        }
    }

    func testIncompleteIdentityOrNativeFailureCannotSettle() throws {
        for scenario in 0..<4 {
            let f = try Fixture(); defer { f.cleanup() }
            if scenario == 0 { f.identityAvailable = false }
            if scenario == 1 { f.wrongIdentity = true }
            if scenario == 2 { f.completeFails = true }
            if scenario == 3 { f.baselineAfterEnable = false }
            let verifier = try f.verifier(), token = try XCTUnwrap(verifier.prepareConnectionRecovery())
            try f.prepareRestoring()
            XCTAssertThrowsError(try verifier.restore(confirmation: token))
            let retained = try XCTUnwrap(f.store.load())
            XCTAssertEqual(retained.phase, .restoring)
            XCTAssertTrue(retained.externalDisplay?.pending == true)
            XCTAssertFalse(retained.canClear)
        }
    }

    func testPreparationRequiresDisabledEvidenceAndSafeTopology() throws {
        for scenario in 0..<6 {
            let f = try Fixture(); defer { f.cleanup() }
            switch scenario {
            case 0: f.online = true
            case 1: f.active = true
            case 2: f.lidOpen = false
            case 3: f.internalMain = false
            case 4: f.mirrored = true
            default: f.foreign = true
            }
            let verifier = try f.verifier(), record = try f.store.load()
            XCTAssertThrowsError(try verifier.prepareConnectionRecovery())
            XCTAssertEqual(try f.store.load(), record)
            XCTAssertTrue(f.events.isEmpty)
        }
    }

    func testUnresolvedSourceRemainsUnsettledWithoutBaseline() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var unresolved = try RecoveryRecord(session: XCTUnwrap(f.store.load()).session, baseline: f.baseline, target: layoutByMakingMain(f.baseline, target: f.internalID),
            externalDisplay: ExternalDisplayResponsibility(identity: f.identity, numericIDHint: 2, baseline: true, applied: false))
        try unresolved.markApplying()
        XCTAssertThrowsError(try unresolved.confirmApplied(f.baseline, internalEnabled: true, externalEnabled: true))
        XCTAssertTrue(unresolved.sourceUnresolved)
        try f.store.save(unresolved)
        f.baselineAfterEnable = false
        let verifier = try f.verifier(), token = try XCTUnwrap(verifier.prepareConnectionRecovery())
        try f.prepareRestoring()
        XCTAssertThrowsError(try verifier.restore(confirmation: token))
        let stored = try XCTUnwrap(f.store.load())
        XCTAssertTrue(stored.sourceUnresolved)
        XCTAssertFalse(stored.canClear)
    }

    func testLowLevelRevalidationCancelsAndAcceptsOnlyValidTransition() throws {
        for scenario in 0..<7 {
            let f = try Fixture(); defer { f.cleanup() }
            try f.prepareRestoring()
            let record = try XCTUnwrap(f.expectedRestoring)
            var configured = false
            f.afterConfigure = { configured = true }
            let result = Result {
                try f.transaction().enableExternalConnectionForRecovery(record: record, loadRecord: { record },
                    observationReader: {
                        guard configured else { return f.evidence() }
                        switch scenario {
                        case 1: return f.evidence(id: 3)
                        case 2: return f.evidence(path: "different")
                        case 3: return .identified(f.state(id: 3))
                        case 4: return f.evidence(online: true, active: true)
                        case 5: return .identified(f.state())
                        case 6:
                            let wrong = ExternalDisplayIdentity(uuid: UUID(), registryPath: f.identity.registryPath,
                                edidUUID: f.identity.edidUUID, bootSession: f.boot, registryEntryID: 7)
                            return .identified(f.state(identity: wrong))
                        default: return f.evidence()
                        }
                    }, checkAccess: { if scenario == 0 && configured { throw RecoveryError.invalidTransition } })
            }
            if scenario == 4 || scenario == 5 {
                XCTAssertNoThrow(try result.get())
                XCTAssertEqual(f.events.last, "complete")
            } else {
                XCTAssertThrowsError(try result.get())
                XCTAssertEqual(f.events.last, "cancel")
                XCTAssertFalse(f.events.contains("complete"))
            }
        }
    }
    func testOnlyOfflineAndInactiveConnectionCanConfirmApplied() throws {
        for scenario in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }
            var applying = try RecoveryRecord(session: XCTUnwrap(f.store.load()).session, baseline: f.baseline, target: layoutByMakingMain(f.baseline, target: f.internalID),
                externalDisplay: ExternalDisplayResponsibility(identity: f.identity, numericIDHint: 2, baseline: true, applied: false))
            try applying.markApplying()
            try f.store.save(applying)
            f.online = scenario == 1
            f.active = scenario == 2
            let verifier = try f.verifier()
            if scenario == 0 {
                XCTAssertEqual(try verifier.reconcile(allowReapplication: false), .applied)
                XCTAssertEqual(try f.store.load()?.phase, .owned)
            } else {
                XCTAssertThrowsError(try verifier.reconcile(allowReapplication: false))
                XCTAssertEqual(try f.store.load(), applying)
            }
            XCTAssertTrue(f.events.isEmpty)
        }
    }

}
