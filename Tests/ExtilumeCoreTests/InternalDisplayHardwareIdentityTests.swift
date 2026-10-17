import Foundation
import XCTest
@testable import ExtilumeCore

final class InternalDisplayHardwareIdentityTests: XCTestCase {
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let bootSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let otherBootSession = UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!

    func testVersionThreeRoundTripsAndConfirmsDisableSubsetAndRecovery() throws {
        let identity = hardwareIdentity()
        let baseline = try layout(distance: -1920)
        let target = try layout(mainExternal: true)
        var record = try recoveryRecord(baseline: baseline, target: target, hardwareIdentity: identity)

        XCTAssertEqual(record.version, 3)
        try record.markApplying()
        try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)

        XCTAssertEqual(record.version, 3)
        XCTAssertEqual(record.preDisableLayout, target)
        XCTAssertEqual(record.internalDisplay?.hardwareIdentity, identity)
        try record.validate()

        let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        try decoded.validate()

        var recovering = decoded
        recovering.beginRestoration()
        try recovering.confirmRestored(actual: baseline, internalEnabled: true)
        XCTAssertEqual(recovering.phase, .restored)
        XCTAssertTrue(recovering.canClear)
        XCTAssertEqual(recovering.version, 3)
        XCTAssertEqual(recovering.internalDisplay?.hardwareIdentity, identity)
        try recovering.validate()
    }

    func testLegacyVersionOneAndTwoRecordsDecodeWithoutInventingHardwareProof() throws {
        let legacyRecord = try recoveryRecord(hardwareIdentity: nil)
        var versionTwoPayload = try payload(legacyRecord)
        removeHardwareIdentity(from: &versionTwoPayload)
        let versionTwo = try decodeRecord(versionTwoPayload)
        XCTAssertEqual(versionTwo.version, 2)
        XCTAssertNil(versionTwo.internalDisplay?.hardwareIdentity)
        try versionTwo.validate()

        var versionOnePayload = versionTwoPayload
        versionOnePayload["version"] = 1
        versionOnePayload.removeValue(forKey: "preDisableLayout")
        let versionOne = try decodeRecord(versionOnePayload)
        XCTAssertEqual(versionOne.version, 1)
        XCTAssertNil(versionOne.internalDisplay?.hardwareIdentity)
        try versionOne.validate()
    }

    func testInvalidHardwareProofAndRecordVersionPairingsAreRejected() throws {
        XCTAssertThrowsError(try InternalDisplayHardwareIdentity(
            bootSession: bootSession, registryEntryID: 0
        ).validate())
        XCTAssertThrowsError(try InternalDisplayHardwareIdentity(
            bootSession: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, registryEntryID: 1
        ).validate())

        let validRecord = try recoveryRecord(hardwareIdentity: hardwareIdentity())
        var zeroRegistryPayload = try payload(validRecord)
        updateHardwareIdentity(in: &zeroRegistryPayload) { $0["registryEntryID"] = 0 }
        XCTAssertThrowsError(try decodeRecord(zeroRegistryPayload).validate())

        var zeroBootPayload = try payload(validRecord)
        updateHardwareIdentity(in: &zeroBootPayload) {
            $0["bootSession"] = "00000000-0000-0000-0000-000000000000"
        }
        XCTAssertThrowsError(try decodeRecord(zeroBootPayload).validate())

        var proofOnVersionTwo = try payload(validRecord)
        proofOnVersionTwo["version"] = 2
        XCTAssertThrowsError(try decodeRecord(proofOnVersionTwo).validate())

        var zeroHint = try payload(validRecord)
        var internalValue = try XCTUnwrap(zeroHint["internalDisplay"] as? [String: Any])
        internalValue["numericIDHint"] = 0
        zeroHint["internalDisplay"] = internalValue
        XCTAssertThrowsError(try decodeRecord(zeroHint).validate())

        var missingProofOnVersionThree = try payload(recoveryRecord(hardwareIdentity: nil))
        missingProofOnVersionThree["version"] = 3
        XCTAssertThrowsError(try decodeRecord(missingProofOnVersionThree).validate())
    }

    func testHandshakeRequiresExactHardwareScopeAndAllowsGenerationAdvance() throws {
        let identity = hardwareIdentity()
        let record = try recoveryRecord(hardwareIdentity: identity)
        let contract = try handshake(hardwareIdentity: identity)

        XCTAssertEqual(contract.version, 2)
        XCTAssertTrue(contract.accepts(record: record))
        XCTAssertFalse(contract.accepts(record: try recoveryRecord(
            hardwareIdentity: hardwareIdentity(bootSession: otherBootSession)
        )))
        XCTAssertFalse(contract.accepts(record: try recoveryRecord(
            hardwareIdentity: hardwareIdentity(registryEntryID: 72)
        )))

        var advanced = record
        try advanced.markApplying()
        try advanced.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        let target = try layout(mainExternal: true)
        try advanced.prepareReapplication(current: try externalOnlyLayout(), target: target)

        XCTAssertEqual(advanced.generation, 2)
        XCTAssertEqual(advanced.internalDisplay?.hardwareIdentity, identity)
        XCTAssertTrue(contract.accepts(record: advanced))
        try advanced.validate()
    }

    func testHandshakeV1CompatibilityOmitsNilProofAndRejectsMismatches() throws {
        let legacyPayload = Data(#"{"version":1,"session":"11111111-2222-4333-8444-555555555555","generation":1,"parentPID":42}"#.utf8)
        let legacy = try JSONDecoder().decode(ProtectionHandshake.self, from: legacyPayload)
        XCTAssertEqual(legacy.version, 1)
        XCTAssertNil(legacy.internalDisplayHardwareIdentity)
        let encodedLegacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as? [String: Any])
        XCTAssertNil(encodedLegacy["internalDisplayHardwareIdentity"])

        let proof = hardwareIdentity()
        let valid = try handshake(hardwareIdentity: proof)
        var proofOnVersionOne = try handshakePayload(valid)
        proofOnVersionOne["version"] = 1
        XCTAssertThrowsError(try decodeHandshake(proofOnVersionOne))

        var missingProofOnVersionTwo = try handshakePayload(valid)
        missingProofOnVersionTwo.removeValue(forKey: "internalDisplayHardwareIdentity")
        XCTAssertThrowsError(try decodeHandshake(missingProofOnVersionTwo))

        var invalidProof = try handshakePayload(valid)
        var hardwarePayload = try XCTUnwrap(invalidProof["internalDisplayHardwareIdentity"] as? [String: Any])
        hardwarePayload["registryEntryID"] = 0
        invalidProof["internalDisplayHardwareIdentity"] = hardwarePayload
        XCTAssertThrowsError(try decodeHandshake(invalidProof))

        XCTAssertThrowsError(try ProtectionHandshake(
            session: session, generation: 1, parentPID: 42,
            internalDisplayHardwareIdentity: proof
        ))
    }

    func testCancelBeforeApplicationPreservesHardwareProof() throws {
        let identity = hardwareIdentity()
        var record = try recoveryRecord(hardwareIdentity: identity)
        try record.markApplying()

        try record.cancelBeforeApplication(previous: nil)

        XCTAssertEqual(record.version, 3)
        XCTAssertEqual(record.phase, .owned)
        XCTAssertEqual(record.applied, record.baseline)
        XCTAssertEqual(record.internalDisplay?.hardwareIdentity, identity)
        XCTAssertEqual(record.internalDisplay?.applied, true)
        XCTAssertEqual(record.internalDisplay?.pending, false)
        try record.validate()
    }

    private func hardwareIdentity(
        bootSession: UUID? = nil,
        registryEntryID: UInt64 = 71
    ) -> InternalDisplayHardwareIdentity {
        InternalDisplayHardwareIdentity(
            bootSession: bootSession ?? self.bootSession,
            registryEntryID: registryEntryID
        )
    }

    private func recoveryRecord(
        session: UUID? = nil,
        baseline: DisplayLayout? = nil,
        target: DisplayLayout? = nil,
        hardwareIdentity: InternalDisplayHardwareIdentity?
    ) throws -> RecoveryRecord {
        try RecoveryRecord(
            session: session ?? self.session,
            baseline: try baseline ?? layout(),
            target: try target ?? layout(mainExternal: true),
            internalDisplay: InternalDisplayResponsibility(
                identity: internalID,
                baseline: true,
                applied: false,
                hardwareIdentity: hardwareIdentity
            )
        )
    }

    private func handshake(
        generation: UInt64 = 1,
        hardwareIdentity: InternalDisplayHardwareIdentity
    ) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: session,
            generation: generation,
            parentPID: 42,
            internalDisplayIdentity: internalID,
            internalDisplayHardwareIdentity: hardwareIdentity
        )
    }

    private func layout(mainExternal: Bool = false, distance: Int32 = 1728) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? -distance : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : distance, y: 0)
        ])
    }

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func payload(_ record: RecoveryRecord) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    private func decodeRecord(_ payload: [String: Any]) throws -> RecoveryRecord {
        try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func removeHardwareIdentity(from payload: inout [String: Any]) {
        guard var internalDisplay = payload["internalDisplay"] as? [String: Any] else { return }
        internalDisplay.removeValue(forKey: "hardwareIdentity")
        payload["internalDisplay"] = internalDisplay
    }

    private func updateHardwareIdentity(
        in payload: inout [String: Any],
        update: (inout [String: Any]) -> Void
    ) {
        guard var internalDisplay = payload["internalDisplay"] as? [String: Any],
              var hardwareIdentity = internalDisplay["hardwareIdentity"] as? [String: Any] else { return }
        update(&hardwareIdentity)
        internalDisplay["hardwareIdentity"] = hardwareIdentity
        payload["internalDisplay"] = internalDisplay
    }

    private func handshakePayload(_ handshake: ProtectionHandshake) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any])
    }

    private func decodeHandshake(_ payload: [String: Any]) throws -> ProtectionHandshake {
        try JSONDecoder().decode(ProtectionHandshake.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
