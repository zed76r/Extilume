import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalHardwareIdentityTests: XCTestCase {
    private let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    private let reportedUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
    private let otherReportedUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000023")!
    private let externalUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000024")!
    private let bootSession = UUID(uuidString: "11111111-2222-4333-8444-555555555556")!
    private let otherBootSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeef")!

    private var hardwareIdentity: InternalDisplayHardwareIdentity {
        InternalDisplayHardwareIdentity(bootSession: bootSession, registryEntryID: 100)
    }

    private func state(
        id: UInt32,
        identityUUID: UUID,
        hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
        reportedIdentityUUID: UUID? = nil,
        isBuiltIn: Bool = true,
        isOnline: Bool = false,
        isActive: Bool = false
    ) -> InternalDisplayState {
        InternalDisplayState(
            id: id,
            identityUUID: identityUUID,
            isBuiltIn: isBuiltIn,
            isOnline: isOnline,
            isActive: isActive,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: reportedIdentityUUID
        )
    }

    private func assertIdentityConflict<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .identityConflict = recoveryError else {
                XCTFail("Expected RecoveryError.identityConflict, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testMapsOfflineBuiltinWithSameBootAndRegistryProof() throws {
        let expected = state(
            id: 80,
            identityUUID: reportedUUID,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: reportedUUID
        )

        let actual = try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            candidates: [80]
        ) { _ in expected }

        XCTAssertEqual(actual.id, expected.id)
        XCTAssertEqual(actual.identityUUID, identity)
        XCTAssertEqual(actual.reportedIdentityUUID, reportedUUID)
        XCTAssertEqual(actual.hardwareIdentity, hardwareIdentity)
        XCTAssertFalse(actual.isEnabled)
    }

    func testRequiresTheSameBootAndRegistryProofEvenWhenUUIDMatches() {
        let changedRegistry = InternalDisplayHardwareIdentity(bootSession: bootSession, registryEntryID: 101)
        let changedBoot = InternalDisplayHardwareIdentity(bootSession: otherBootSession, registryEntryID: 100)

        for proof in [changedRegistry, changedBoot] {
            assertIdentityConflict(try matchInternalDisplay(
                identity: identity,
                hardwareIdentity: hardwareIdentity,
                candidates: [80]
            ) { _ in
                state(id: 80, identityUUID: reportedUUID, hardwareIdentity: proof, reportedIdentityUUID: reportedUUID)
            })
        }

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            candidates: [80]
        ) { _ in
            state(id: 80, identityUUID: identity, hardwareIdentity: changedRegistry, reportedIdentityUUID: identity)
        })
    }

    func testRejectsDuplicateProofOrReportedUUIDAcrossCandidates() {
        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            candidates: [80, 81]
        ) { id in
            state(
                id: id,
                identityUUID: id == 80 ? reportedUUID : otherReportedUUID,
                hardwareIdentity: hardwareIdentity,
                reportedIdentityUUID: id == 80 ? reportedUUID : otherReportedUUID
            )
        })

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            candidates: [80, 40]
        ) { id in
            state(
                id: id,
                identityUUID: reportedUUID,
                hardwareIdentity: id == 80 ? hardwareIdentity : nil,
                reportedIdentityUUID: reportedUUID,
                isBuiltIn: id == 80
            )
        })
    }

    func testCanonicalizesOnlyTheInternalDisplayUUIDLabel() throws {
        let internalDisplay = display(
            id: 80,
            identity: .builtIn,
            uuid: reportedUUID,
            isOnline: false,
            isActive: false,
            isMain: false,
            originX: 1920,
            mode: DisplayModeState(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioDisplayModeID: 1)
        )
        let externalDisplay = display(
            id: 40,
            identity: .physical,
            uuid: externalUUID,
            isOnline: true,
            isActive: true,
            isMain: true,
            originX: 0,
            mode: DisplayModeState(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 75, ioDisplayModeID: 2)
        )
        let original = Snapshot(displays: [internalDisplay, externalDisplay])
        let internalState = state(
            id: 80,
            identityUUID: identity,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: reportedUUID
        )

        let canonical = try original.canonicalizingInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            state: internalState
        )

        var expectedInternal = internalDisplay
        expectedInternal.identityUUID = identity
        XCTAssertEqual(canonical.displays, [expectedInternal, externalDisplay])
    }

    func testCanonicalizationRejectsReportedUUIDAndOnlineStateChanges() {
        let snapshot = snapshot(internalUUID: reportedUUID, externalUUID: externalUUID)
        let wrongReportedUUID = state(
            id: 80,
            identityUUID: identity,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: otherReportedUUID
        )
        assertIdentityConflict(try snapshot.canonicalizingInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            state: wrongReportedUUID
        ))

        for transitionedState in [
            state(id: 80, identityUUID: identity, hardwareIdentity: hardwareIdentity, reportedIdentityUUID: reportedUUID, isOnline: true),
            state(id: 80, identityUUID: identity, hardwareIdentity: hardwareIdentity, reportedIdentityUUID: reportedUUID, isActive: true)
        ] {
            assertIdentityConflict(try snapshot.canonicalizingInternalDisplay(
                identity: identity,
                hardwareIdentity: hardwareIdentity,
                state: transitionedState
            ))
        }
    }

    func testCanonicalizationRejectsExternalUUIDConflict() {
        let snapshot = snapshot(internalUUID: reportedUUID, externalUUID: identity)
        let internalState = state(
            id: 80,
            identityUUID: identity,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: reportedUUID
        )

        assertIdentityConflict(try snapshot.canonicalizingInternalDisplay(
            identity: identity,
            hardwareIdentity: hardwareIdentity,
            state: internalState
        ))
    }

    private func snapshot(internalUUID: UUID, externalUUID: UUID) -> Snapshot {
        Snapshot(displays: [
            display(id: 80, identity: .builtIn, uuid: internalUUID, isOnline: false, isActive: false, isMain: false, originX: 1920,
                    mode: DisplayModeState(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioDisplayModeID: 1)),
            display(id: 40, identity: .physical, uuid: externalUUID, isOnline: true, isActive: true, isMain: true, originX: 0,
                    mode: DisplayModeState(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 75, ioDisplayModeID: 2))
        ])
    }

    private func display(
        id: UInt32,
        identity: DisplayIdentity,
        uuid: UUID,
        isOnline: Bool,
        isActive: Bool,
        isMain: Bool,
        originX: CGFloat,
        mode: DisplayModeState
    ) -> DisplayState {
        DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: isOnline,
            isActive: isActive,
            isMain: isMain,
            isMirrored: false,
            originX: originX,
            originY: 0,
            width: CGFloat(mode.width),
            height: CGFloat(mode.height),
            rotation: 0,
            mode: mode
        )
    }
}
