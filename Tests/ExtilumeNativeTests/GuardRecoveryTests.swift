import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class GuardRecoveryTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private enum FixtureError: Error { case injected }

    func testUnchangedLayoutIsRecordedRestoredWithoutWritingOrigins() throws {
        let baseline = try layout()
        let record = try applyingRecord(baseline: baseline, target: baseline, includesInternal: false)

        try withStore { store, _ in
            try store.save(record)
            var writes = 0
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { self.snapshot(baseline) },
                enableInternal: { _ in XCTFail("unexpected internal enable") },
                originWriter: { _ in writes += 1 }
            )

            XCTAssertEqual(writes, 0)
            XCTAssertTrue(restored.canClear)
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testAlreadyEnabledInternalDisplaySkipsEnableAndRestoresRecord() throws {
        let baseline = try layout()
        let record = try ownedRecord(baseline: baseline, target: baseline)

        try withStore { store, _ in
            try store.save(record)
            var enables = 0
            var writes = 0
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { self.snapshot(baseline, internalActive: true) },
                enableInternal: { _ in enables += 1 },
                originWriter: { _ in writes += 1 }
            )

            XCTAssertEqual(enables, 0)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertFalse(try XCTUnwrap(restored.internalDisplay).pending)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testApplyingRecordEnablesBeforeRestoringOrigins() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var events: [String] = []
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: {
                    events.append("snapshot")
                    return current
                },
                enableInternal: { restoring in
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    events.append("enable")
                    current = self.snapshot(target, internalActive: true)
                },
                originWriter: { origins in
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    events.append("origins")
                    XCTAssertEqual(origins, [
                        80: DisplayOrigin(x: 0, y: 0),
                        40: DisplayOrigin(x: 1728, y: 0)
                    ])
                    current = self.snapshot(baseline)
                }
            )

            XCTAssertEqual(events.filter { $0 == "enable" || $0 == "origins" }, ["enable", "origins"])
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testEnableFailureOrInactiveReadbackLeavesRestorationPending() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        for shouldThrow in [true, false] {
            try withStore { store, _ in
                try store.save(record)
                var enableCalls = 0
                var writes = 0
                do {
                    _ = try recoverGuardRecord(
                        store: store,
                        contract: contract(for: record),
                        snapshotReader: { self.snapshot(target, internalActive: false) },
                        enableInternal: { restoring in
                            enableCalls += 1
                            XCTAssertEqual(restoring.phase, .restoring)
                            XCTAssertEqual(try store.load()?.phase, .restoring)
                            if shouldThrow { throw FixtureError.injected }
                        },
                        originWriter: { _ in writes += 1 }
                    )
                    XCTFail("recovery should remain pending")
                } catch {
                    if shouldThrow {
                        XCTAssertTrue(error is FixtureError)
                    } else if let recoveryError = error as? RecoveryError,
                              case .unfinishedTransaction = recoveryError {
                        // The independent readback still reports the built-in display inactive.
                    } else {
                        XCTFail("unexpected error: \(error)")
                    }
                }

                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(enableCalls, 1)
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(retained.phase, .restoring)
                XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            }
        }
    }

    func testUnresolvedSourceEnablesInternalButNeverWritesLayout() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(
            baseline: baseline,
            target: target,
            unresolvedLayout: try layout(mainExternal: true, internalX: -1900)
        )

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var enables = 0
            var writes = 0
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                enableInternal: { restoring in
                    enables += 1
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertTrue(restoring.sourceUnresolved)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    current = self.snapshot(target, internalActive: true)
                },
                originWriter: { _ in writes += 1 }
            ))

            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(enables, 1)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(retained.phase, .restoring)
            XCTAssertTrue(retained.sourceUnresolved)
            XCTAssertTrue(retained.layoutPending)
        }
    }

    func testInvalidHandshakeScopeDoesNotCallBackOrChangeRecordBytes() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, directory in
            try store.save(record)
            let recordURL = directory.appendingPathComponent("recovery-record.json")
            let originalBytes = try Data(contentsOf: recordURL)
            let contracts = [
                try ProtectionHandshake(session: otherSession, generation: record.generation, parentPID: 42, internalDisplayIdentity: internalID),
                try ProtectionHandshake(session: session, generation: record.generation + 1, parentPID: 42, internalDisplayIdentity: internalID),
                try ProtectionHandshake(session: session, generation: record.generation, parentPID: 42, internalDisplayIdentity: otherID),
                try ProtectionHandshake(session: session, generation: record.generation, parentPID: 42)
            ]
            var callbacks = 0

            for contract in contracts {
                XCTAssertThrowsError(try recoverGuardRecord(
                    store: store,
                    contract: contract,
                    snapshotReader: { callbacks += 1; return self.snapshot(baseline) },
                    enableInternal: { _ in callbacks += 1 },
                    originWriter: { _ in callbacks += 1 }
                ))
                XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
            }
            XCTAssertEqual(callbacks, 0)
        }

        let noScopeRecord = try applyingRecord(baseline: baseline, target: target, includesInternal: false)
        try withStore { store, directory in
            try store.save(noScopeRecord)
            let recordURL = directory.appendingPathComponent("recovery-record.json")
            let originalBytes = try Data(contentsOf: recordURL)
            var callbacks = 0
            let scopedContract = try ProtectionHandshake(
                session: noScopeRecord.session,
                generation: noScopeRecord.generation,
                parentPID: 42,
                internalDisplayIdentity: internalID
            )

            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: scopedContract,
                snapshotReader: { callbacks += 1; return self.snapshot(baseline) },
                enableInternal: { _ in callbacks += 1 },
                originWriter: { _ in callbacks += 1 }
            ))
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
        }
    }

    func testMissingExternalEnablesInternalAndRetainsLayoutResponsibility() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(baseline, internalActive: false, includeExternal: false)
            var events: [String] = []
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                enableInternal: { restoring in
                    events.append("enable")
                    XCTAssertEqual(restoring.phase, .restoring)
                    current = self.snapshot(baseline, includeExternal: false)
                },
                originWriter: { origins in
                    events.append("origins")
                    XCTAssertEqual(origins, [80: DisplayOrigin(x: 0, y: 0)])
                }
            ))

            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(events, ["enable", "origins"])
            XCTAssertEqual(current.displays.first(where: { $0.identity == .builtIn })?.isActive, true)
            XCTAssertEqual(retained.phase, .restoring)
            XCTAssertTrue(retained.layoutPending)
            XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            XCTAssertFalse(retained.canClear)
        }
    }

    func testHigherGenerationWrittenAfterEnableBlocksOriginsAndKeepsNewRecord() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)
        var newer = try RecoveryRecord(
            session: record.session,
            baseline: baseline,
            target: target,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        )
        try newer.confirmApplied(target, internalEnabled: false)
        try newer.prepareReapplication(current: target, target: try layout(mainExternal: true, internalX: -1900))

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var writes = 0
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                enableInternal: { restoring in
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    current = self.snapshot(target, internalActive: true)
                    try store.save(newer)
                },
                originWriter: { _ in writes += 1 }
            ))

            XCTAssertEqual(writes, 0)
            XCTAssertEqual(try store.load(), newer)
            XCTAssertGreaterThan(try XCTUnwrap(store.load()).generation, record.generation)
        }
    }

    private func applyingRecord(
        baseline: DisplayLayout? = nil,
        target: DisplayLayout? = nil,
        includesInternal: Bool = true,
        unresolvedLayout: DisplayLayout? = nil,
        session: UUID? = nil
    ) throws -> RecoveryRecord {
        let baseline = try baseline ?? layout()
        let target = try target ?? layout(mainExternal: true)
        var record = try RecoveryRecord(
            session: session ?? self.session,
            baseline: baseline,
            target: target,
            internalDisplay: includesInternal
                ? InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
                : nil
        )
        try record.markApplying()
        if let unresolvedLayout { try record.observe(unresolvedLayout, source: .unknown) }
        return record
    }

    private func ownedRecord(
        baseline: DisplayLayout,
        target: DisplayLayout,
        includesInternal: Bool = true
    ) throws -> RecoveryRecord {
        var record = try applyingRecord(baseline: baseline, target: target, includesInternal: includesInternal)
        try record.confirmApplied(target, internalEnabled: includesInternal ? false : nil)
        return record
    }

    private func contract(for record: RecoveryRecord) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: record.session,
            generation: record.generation,
            parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity
        )
    }

    private func layout(mainExternal: Bool = false, internalX: Int32? = nil) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? (internalX ?? -1728) : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : 1728, y: 0)
        ])
    }

    private func snapshot(
        _ layout: DisplayLayout,
        internalActive: Bool = true,
        includeExternal: Bool = true
    ) -> Snapshot {
        var displays = [makeDisplay(id: 80, identity: .builtIn, uuid: internalID, layout: layout, isActive: internalActive)]
        if includeExternal {
            displays.append(makeDisplay(id: 40, identity: .physical, uuid: externalID, layout: layout))
        }
        return Snapshot(displays: displays)
    }

    private func makeDisplay(
        id: UInt32,
        identity: DisplayIdentity,
        uuid: UUID,
        layout: DisplayLayout,
        isActive: Bool = true
    ) -> DisplayState {
        let origin = layout.origins[uuid] ?? DisplayOrigin(x: 0, y: 0)
        return DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: true,
            isActive: isActive,
            isMain: layout.main == uuid,
            isMirrored: false,
            originX: CGFloat(origin.x),
            originY: CGFloat(origin.y),
            width: 1920,
            height: 1080,
            rotation: 0,
            mode: DisplayModeState(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioDisplayModeID: 1)
        )
    }

    private func withStore(_ body: (RecoveryStore, URL) throws -> Void) throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/extilume-guard-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(directory.path, mode_t(0o700)) == 0 else { throw RecoveryStoreError.ioFailure }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw RecoveryStoreError.ioFailure
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try body(store, directory)
    }
}
