import Foundation
import XCTest
@testable import ExtilumeCore

final class ProtectionHandshakeTests: XCTestCase {
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let firstDisplay = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let secondDisplay = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    func testAuthorizationStartsUnready() throws {
        let authorization = ProtectionAuthorization()

        XCTAssertFalse(authorization.ready)
        XCTAssertFalse(authorization.lost)
        XCTAssertThrowsError(try authorization.authorize(record: makeRecord()))
    }

    func testAcknowledgementRequiresFullValidContractEquality() throws {
        let expected = try handshake(internalDisplayIdentity: firstDisplay)
        try expected.validate()
        let encoded = try JSONEncoder().encode(expected)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(payload["internalDisplayIdentity"])
        let decoded = try JSONDecoder().decode(ProtectionHandshake.self, from: encoded)
        XCTAssertEqual(decoded, expected)

        let wrongPID = try ProtectionHandshake(
            session: session, generation: 1, parentPID: 43, internalDisplayIdentity: firstDisplay
        )
        var authorization = ProtectionAuthorization()

        XCTAssertThrowsError(try authorization.acknowledge(receipt: wrongPID, expected: expected))
        XCTAssertFalse(authorization.ready)
        try authorization.acknowledge(receipt: expected, expected: expected)
        XCTAssertTrue(authorization.ready)
    }

    func testLegacyHandshakeWithoutInternalIdentityDecodesToNilAndOmitsNilWhenEncoded() throws {
        let decoded = try JSONDecoder().decode(ProtectionHandshake.self, from: encoded())

        XCTAssertNil(decoded.internalDisplayIdentity)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(payload["internalDisplayIdentity"])
    }

    func testRejectsDifferentSessionAndOlderGeneration() throws {
        let contract = try handshake(generation: 2)
        let differentSession = try makeRecord(session: otherSession)
        XCTAssertFalse(contract.accepts(record: differentSession))

        let older = try makeRecord()
        XCTAssertFalse(contract.accepts(record: older))
    }

    func testVerifyAcknowledgementAcceptsOwnedRecordWithoutAuthorizingControl() throws {
        let hardware = InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 42)
        let contract = try handshake(
            internalDisplayIdentity: firstDisplay, internalDisplayHardwareIdentity: hardware
        )
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract, expected: contract)

        var owned = try makeRecord(
            internalDisplayIdentity: firstDisplay, internalDisplayHardwareIdentity: hardware
        )
        try owned.markApplying()
        try owned.confirmApplied(DisplayLayout(main: secondDisplay, origins: [
            secondDisplay: DisplayOrigin(x: 0, y: 0)
        ]), internalEnabled: false)
        XCTAssertEqual(owned.phase, .owned)

        XCTAssertNoThrow(try authorization.verifyAcknowledgement(record: owned))
        XCTAssertTrue(authorization.ready)
        XCTAssertFalse(authorization.lost)
        XCTAssertThrowsError(try authorization.authorize(record: owned)) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .invalidTransition = recoveryError else {
                return XCTFail("owned record should fail only the control-phase check")
            }
        }
    }

    func testVerifyAcknowledgementRejectsUnreadyAndLostAuthorization() throws {
        let contract = try handshake()
        let record = try makeRecord()
        var authorization = ProtectionAuthorization()

        assertThrowsUnfinishedTransaction(try authorization.verifyAcknowledgement(record: record))

        try authorization.acknowledge(receipt: contract, expected: contract)
        authorization.markLost()
        assertThrowsUnfinishedTransaction(try authorization.verifyAcknowledgement(record: record))
        XCTAssertTrue(authorization.lost)
        XCTAssertFalse(authorization.ready)
    }

    func testVerifyAcknowledgementRejectsMismatchedRecordBinding() throws {
        let hardwareIdentity = InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 42)
        let otherHardwareIdentity = InternalDisplayHardwareIdentity(bootSession: otherSession, registryEntryID: 43)

        let contract = try handshake(
            internalDisplayIdentity: firstDisplay,
            internalDisplayHardwareIdentity: hardwareIdentity
        )
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract, expected: contract)

        assertThrowsIdentityConflict(try authorization.verifyAcknowledgement(record: makeRecord(
            session: otherSession,
            internalDisplayIdentity: firstDisplay,
            internalDisplayHardwareIdentity: hardwareIdentity
        )))
        assertThrowsIdentityConflict(try authorization.verifyAcknowledgement(record: makeRecord(
            internalDisplayIdentity: secondDisplay,
            internalDisplayHardwareIdentity: hardwareIdentity
        )))
        assertThrowsIdentityConflict(try authorization.verifyAcknowledgement(record: makeRecord(
            internalDisplayIdentity: firstDisplay,
            internalDisplayHardwareIdentity: otherHardwareIdentity
        )))
        assertThrowsIdentityConflict(try authorization.verifyAcknowledgement(record: makeRecord()))

        let newerGenerationContract = try handshake(generation: 2)
        var newerGenerationAuthorization = ProtectionAuthorization()
        try newerGenerationAuthorization.acknowledge(
            receipt: newerGenerationContract,
            expected: newerGenerationContract
        )
        assertThrowsIdentityConflict(try newerGenerationAuthorization.verifyAcknowledgement(record: makeRecord()))
    }

    func testAcceptsNewerGenerationInPreparedAndApplyingPhases() throws {
        let contract = try handshake()
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract, expected: contract)

        var prepared = try makeRecord()
        try prepared.markApplying()
        try prepared.confirmApplied(prepared.applied)
        let current = prepared.applied
        try prepared.prepareReapplication(current: current, target: current)
        XCTAssertEqual(prepared.generation, 2)
        XCTAssertTrue(contract.accepts(record: prepared))
        XCTAssertNoThrow(try authorization.authorize(record: prepared))

        try prepared.markApplying()
        XCTAssertNoThrow(try authorization.authorize(record: prepared))
    }

    func testAcceptanceRequiresMatchingInternalDisplayIdentityAndAllowsNewerGeneration() throws {
        let unscoped = try handshake()
        let withResponsibility = try makeRecord(internalDisplayIdentity: firstDisplay)
        XCTAssertFalse(unscoped.accepts(record: withResponsibility))

        let scoped = try handshake(internalDisplayIdentity: firstDisplay)
        let withoutResponsibility = try makeRecord()
        let withOtherIdentity = try makeRecord(internalDisplayIdentity: secondDisplay)
        XCTAssertFalse(scoped.accepts(record: withoutResponsibility))
        XCTAssertFalse(scoped.accepts(record: withOtherIdentity))

        var newer = try makeRecord(internalDisplayIdentity: firstDisplay)
        try newer.markApplying()
        let target = newer.applied
        try newer.confirmApplied(DisplayLayout(main: secondDisplay, origins: [
            secondDisplay: DisplayOrigin(x: 0, y: 0)
        ]), internalEnabled: false)
        let current = newer.applied
        try newer.prepareReapplication(current: current, target: target)

        XCTAssertGreaterThan(newer.generation, scoped.generation)
        XCTAssertTrue(scoped.accepts(record: newer))
    }

    func testWrongInternalScopeAcknowledgementRevokesPreviousReadiness() throws {
        let firstScope = try handshake(internalDisplayIdentity: firstDisplay)
        let otherScope = try handshake(internalDisplayIdentity: secondDisplay)
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: firstScope, expected: firstScope)
        XCTAssertTrue(authorization.ready)

        XCTAssertThrowsError(try authorization.acknowledge(receipt: firstScope, expected: otherScope))
        XCTAssertFalse(authorization.ready)
        XCTAssertThrowsError(try authorization.authorize(record: makeRecord(internalDisplayIdentity: firstDisplay)))
    }

    func testFailedNewGenerationAcknowledgementRevokesPreviousReadiness() throws {
        let contract1 = try handshake(generation: 1)
        let contract2 = try handshake(generation: 2)
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract1, expected: contract1)

        var record2 = try makeRecord()
        try record2.markApplying()
        try record2.confirmApplied(record2.applied)
        let current = record2.applied
        try record2.prepareReapplication(current: current, target: current)
        XCTAssertEqual(record2.generation, 2)

        XCTAssertThrowsError(try authorization.acknowledge(receipt: contract1, expected: contract2))
        XCTAssertFalse(authorization.ready)
        XCTAssertThrowsError(try authorization.authorize(record: record2))

        try authorization.acknowledge(receipt: contract2, expected: contract2)
        XCTAssertTrue(authorization.ready)
        XCTAssertNoThrow(try authorization.authorize(record: record2))
    }

    func testRejectsNonControlPhaseAndUnresolvedSource() throws {
        let contract = try handshake()
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract, expected: contract)

        var owned = try makeRecord()
        try owned.markApplying()
        try owned.confirmApplied(owned.applied)
        XCTAssertThrowsError(try authorization.authorize(record: owned))

        var unresolved = try makeRecord()
        try unresolved.observe(changedLayout(), source: .unknown)
        XCTAssertTrue(unresolved.sourceUnresolved)
        XCTAssertThrowsError(try authorization.authorize(record: unresolved))
    }

    func testRejectsInvalidDecodedVersionGenerationAndPID() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(ProtectionHandshake.self, from: encoded(version: 2)))
        XCTAssertThrowsError(try JSONDecoder().decode(ProtectionHandshake.self, from: encoded(generation: 0)))
        XCTAssertThrowsError(try JSONDecoder().decode(ProtectionHandshake.self, from: encoded(parentPID: 1)))
        XCTAssertThrowsError(try ProtectionHandshake(session: session, generation: 0, parentPID: 2))
        XCTAssertThrowsError(try ProtectionHandshake(session: session, generation: 1, parentPID: 1))
        XCTAssertNoThrow(try ProtectionHandshake(session: session, generation: 1, parentPID: 2).validate())
    }

    func testLostAuthorizationCannotBeReestablished() throws {
        let contract = try handshake()
        var authorization = ProtectionAuthorization()
        try authorization.acknowledge(receipt: contract, expected: contract)
        authorization.markLost()

        XCTAssertTrue(authorization.lost)
        XCTAssertFalse(authorization.ready)
        XCTAssertThrowsError(try authorization.acknowledge(receipt: contract, expected: contract))
        XCTAssertThrowsError(try authorization.authorize(record: makeRecord()))
    }

    func testLossBeforeReadyRejectsLateCorrectAcknowledgement() throws {
        let contract = try handshake()
        var authorization = ProtectionAuthorization()
        authorization.markLost()

        XCTAssertTrue(authorization.lost)
        XCTAssertFalse(authorization.ready)
        XCTAssertThrowsError(try authorization.acknowledge(receipt: contract, expected: contract))
        XCTAssertThrowsError(try authorization.authorize(record: makeRecord()))
    }

    private func handshake(
        generation: UInt64 = 1,
        internalDisplayIdentity: UUID? = nil,
        internalDisplayHardwareIdentity: InternalDisplayHardwareIdentity? = nil
    ) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: session,
            generation: generation,
            parentPID: 42,
            internalDisplayIdentity: internalDisplayIdentity,
            internalDisplayHardwareIdentity: internalDisplayHardwareIdentity
        )
    }

    private func makeRecord(
        session: UUID? = nil,
        internalDisplayIdentity: UUID? = nil,
        internalDisplayHardwareIdentity: InternalDisplayHardwareIdentity? = nil
    ) throws -> RecoveryRecord {
        try RecoveryRecord(
            session: session ?? self.session,
            baseline: DisplayLayout(main: firstDisplay, origins: [
                firstDisplay: DisplayOrigin(x: 0, y: 0),
                secondDisplay: DisplayOrigin(x: 100, y: 0)
            ]),
            target: DisplayLayout(main: secondDisplay, origins: [
                firstDisplay: DisplayOrigin(x: -100, y: 0),
                secondDisplay: DisplayOrigin(x: 0, y: 0)
            ]),
            internalDisplay: internalDisplayIdentity.map {
                InternalDisplayResponsibility(
                    identity: $0,
                    baseline: true,
                    applied: false,
                    hardwareIdentity: internalDisplayHardwareIdentity
                )
            }
        )
    }

    private func assertThrowsUnfinishedTransaction(
        _ expression: @autoclosure () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .unfinishedTransaction = recoveryError else {
                return XCTFail("expected unfinishedTransaction", file: file, line: line)
            }
        }
    }

    private func assertThrowsIdentityConflict(
        _ expression: @autoclosure () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .identityConflict = recoveryError else {
                return XCTFail("expected identityConflict", file: file, line: line)
            }
        }
    }

    private func changedLayout() throws -> DisplayLayout {
        try DisplayLayout(main: firstDisplay, origins: [
            firstDisplay: DisplayOrigin(x: 0, y: 0),
            secondDisplay: DisplayOrigin(x: 200, y: 0)
        ])
    }

    private func encoded(version: Int = 1, generation: UInt64 = 1, parentPID: Int32 = 42) -> Data {
        Data(#"{"version":\#(version),"session":"\#(session.uuidString)","generation":\#(generation),"parentPID":\#(parentPID)}"#.utf8)
    }
}
