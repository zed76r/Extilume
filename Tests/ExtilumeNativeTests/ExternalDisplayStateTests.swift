import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalDisplayStateTests: XCTestCase {
    private let uuid = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    private let otherUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
    private let bootSession = UUID(uuidString: "00000000-0000-4000-8000-000000000023")!
    private let otherBootSession = UUID(uuidString: "00000000-0000-4000-8000-000000000024")!

    private var identity: ExternalDisplayIdentity {
        ExternalDisplayIdentity(
            uuid: uuid,
            registryPath: "IODeviceTree:/display/hdmi",
            edidUUID: "00000000-0000-4000-8000-000000000025",
            bootSession: bootSession,
            registryEntryID: 42
        )
    }

    private func state(
        id: UInt32,
        identity: ExternalDisplayIdentity? = nil,
        isOnline: Bool = true,
        isActive: Bool = true
    ) -> ExternalDisplayState {
        ExternalDisplayState(
            id: id,
            identity: identity ?? self.identity,
            isOnline: isOnline,
            isActive: isActive
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

    func testSavedHintFindsOfflineDisplayAbsentFromOnlineAndActiveLists() throws {
        var readIDs: [UInt32] = []
        let expected = state(id: 7, isOnline: false, isActive: false)

        let actual = try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [],
            currentBootSession: bootSession
        ) { id in
            readIDs.append(id)
            return id == 7 ? expected : nil
        }

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(readIDs, [7])
        XCTAssertFalse(actual.isEnabled)
    }

    func testChangedDisplayIDUsesStableIdentityDespiteReusedHint() throws {
        let expected = state(id: 42, isOnline: false, isActive: false)
        let reused = state(id: 7, identity: ExternalDisplayIdentity(
            uuid: otherUUID,
            registryPath: "IODeviceTree:/display/other",
            edidUUID: "00000000-0000-4000-8000-000000000026",
            bootSession: bootSession,
            registryEntryID: 43
        ))

        let actual = try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [42],
            currentBootSession: bootSession
        ) { id in id == 42 ? expected : reused }

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isEnabled)
    }

    func testChangedInactiveTargetCanBeFoundOnlyInPrivateSlots() throws {
        let expected = state(id: 42, isOnline: false, isActive: false)
        var reads: [UInt32] = []
        let actual = try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [1],
            privateCandidates: [1, 42, 7, 42], currentBootSession: bootSession
        ) { id in
            reads.append(id)
            return id == 42 ? expected : nil
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(reads, [1, 42, 7])
        XCTAssertFalse(actual.isEnabled)
    }

    func testPrivateSlotMembershipDoesNotAuthorizeAnUnidentifiedTarget() {
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [],
            privateCandidates: [7], currentBootSession: bootSession
        ) { _ in nil })

        let zeroIdentity = ExternalDisplayIdentity(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            registryPath: identity.registryPath, edidUUID: identity.edidUUID,
            bootSession: bootSession, registryEntryID: identity.registryEntryID
        )
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [],
            privateCandidates: [7], currentBootSession: bootSession
        ) { id in self.state(id: id, identity: zeroIdentity, isOnline: false, isActive: false) })
    }

    func testAmbiguousPrivateSlotsRemainRejected() {
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [],
            privateCandidates: [42, 43], currentBootSession: bootSession
        ) { id in id == 7 ? nil : self.state(id: id, isOnline: false, isActive: false) })
    }

    func testPrivateSlotsCannotBypassRegistryOrBootBinding() {
        let differentEntry = ExternalDisplayIdentity(
            uuid: uuid, registryPath: identity.registryPath, edidUUID: identity.edidUUID,
            bootSession: bootSession, registryEntryID: identity.registryEntryID + 1
        )
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [],
            privateCandidates: [42], currentBootSession: bootSession
        ) { id in id == 42 ? self.state(id: id, identity: differentEntry) : nil })

        var read = false
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity, numericIDHint: 7, candidates: [],
            privateCandidates: [42], currentBootSession: otherBootSession
        ) { _ in
            read = true
            return self.state(id: 42)
        })
        XCTAssertFalse(read)
    }

    func testReusedNumericIDCannotMatchAnotherDisplay() {
        let reused = state(id: 7, identity: ExternalDisplayIdentity(
            uuid: otherUUID,
            registryPath: "IODeviceTree:/display/other",
            edidUUID: "00000000-0000-4000-8000-000000000026",
            bootSession: bootSession,
            registryEntryID: 43
        ))

        assertIdentityConflict(try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [],
            currentBootSession: bootSession
        ) { _ in reused })
    }

    func testRegistryPathEDIDOrEntryMismatchIsRejected() {
        let mismatches = [
            ExternalDisplayIdentity(
                uuid: uuid,
                registryPath: "IODeviceTree:/display/reused",
                edidUUID: identity.edidUUID,
                bootSession: bootSession,
                registryEntryID: identity.registryEntryID
            ),
            ExternalDisplayIdentity(
                uuid: uuid,
                registryPath: identity.registryPath,
                edidUUID: "00000000-0000-4000-8000-000000000027",
                bootSession: bootSession,
                registryEntryID: identity.registryEntryID
            ),
            ExternalDisplayIdentity(
                uuid: uuid,
                registryPath: identity.registryPath,
                edidUUID: identity.edidUUID,
                bootSession: bootSession,
                registryEntryID: identity.registryEntryID + 1
            )
        ]

        for mismatch in mismatches {
            assertIdentityConflict(try matchExternalDisplay(
                identity: identity,
                numericIDHint: 7,
                candidates: [],
                currentBootSession: bootSession
            ) { id in self.state(id: id, identity: mismatch) })
        }
    }

    func testMissingAndAmbiguousTargetsAreRejected() {
        assertIdentityConflict(try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [],
            currentBootSession: bootSession
        ) { _ in nil })

        assertIdentityConflict(try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [7, 8],
            currentBootSession: bootSession
        ) { id in self.state(id: id) })
    }

    func testStaleBootBindingIsRejectedBeforeReadingCandidates() {
        var readCandidate = false

        assertIdentityConflict(try matchExternalDisplay(
            identity: identity,
            numericIDHint: 7,
            candidates: [7],
            currentBootSession: otherBootSession
        ) { _ in
            readCandidate = true
            return self.state(id: 7)
        })

        XCTAssertFalse(readCandidate)
    }
}
