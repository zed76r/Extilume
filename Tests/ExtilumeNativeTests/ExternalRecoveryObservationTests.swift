import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalRecoveryObservationTests: XCTestCase {
    private let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let identity = ExternalDisplayIdentity(
        uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!,
        registryPath: "IOService:/display/1", edidUUID: "EDID-1",
        bootSession: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!, registryEntryID: 52
    )

    private func evidence(id: UInt32 = 7, uuid: UUID? = nil, path: String = "IOService:/display/1",
                          edid: String = "EDID-1", boot: UUID? = nil, entry: UInt64 = 52,
                          builtin: Bool = false, online: Bool = false, active: Bool = false,
                          count: Int = 1, excludes: Bool = true, hdmi: Bool = true,
                          classMatches: Bool = true) -> ExternalConnectionEvidence {
        ExternalConnectionEvidence(id: id, observedUUID: uuid ?? zero, registryPath: path, edidUUID: edid,
            bootSession: boot ?? identity.bootSession, registryEntryID: entry, isBuiltin: builtin,
            isOnline: online, isActive: active, matchingSlotCount: count,
            allSlotsExcludeOriginalUUID: excludes, registryIsHDMI: hdmi, registryClassMatches: classMatches)
    }

    func testConnectionEvidenceUsesActualZeroAndChecksEveryIdentityField() throws {
        let valid = evidence()
        XCTAssertTrue(valid.matches(identity: identity, numericIDHint: 7))
        XCTAssertTrue(valid.isDisabled)
        let encoded = try JSONEncoder().encode(ExternalRecoveryObservation.connection(valid))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(identity.uuid.uuidString))
        XCTAssertEqual(try JSONDecoder().decode(ExternalRecoveryObservation.self, from: encoded), .connection(valid))
        XCTAssertTrue(evidence(online: true).matches(identity: identity, numericIDHint: 7))
        XCTAssertFalse(evidence(online: true).isDisabled)
        let invalid = [evidence(id: 0), evidence(id: 8), evidence(uuid: identity.uuid), evidence(path: "other"),
            evidence(edid: "other"), evidence(boot: zero), evidence(entry: 53), evidence(builtin: true),
            evidence(count: 0), evidence(count: 2), evidence(excludes: false), evidence(hdmi: false),
            evidence(classMatches: false)]
        for item in invalid { XCTAssertFalse(item.matches(identity: identity, numericIDHint: 7)) }
        XCTAssertFalse(valid.matches(identity: identity, numericIDHint: 0))
        XCTAssertTrue(ExternalRecoveryObservation.identified(ExternalDisplayState(
            id: 8, identity: identity, isOnline: true, isActive: true
        )).matches(identity: identity, numericIDHint: 7))
    }

    func testSlotAggregationRejectsAmbiguityAndUnreadableMetadata() {
        func slot(_ id: UInt32, _ reported: UInt32?, _ uuid: UUID?, _ location: String?) -> ExternalRecoverySlot {
            ExternalRecoverySlot(id: id, reportedID: reported, uuid: uuid, location: location)
        }
        let target = slot(7, 7, zero, identity.registryPath)
        let other = slot(8, 8, zero, "other")
        XCTAssertNotNil(matchingExternalRecoverySlot([target, other], identity: identity, numericIDHint: 7))
        XCTAssertNotNil(matchingExternalRecoverySlot([target, slot(8, 8, zero, nil)], identity: identity, numericIDHint: 7))
        let invalid: [[ExternalRecoverySlot]] = [[], [other], [target, target],
            [target, slot(8, 8, zero, identity.registryPath)], [slot(7, nil, zero, identity.registryPath)],
            [slot(7, 8, zero, identity.registryPath)], [slot(7, 7, nil, identity.registryPath)],
            [slot(7, 7, zero, nil)], [slot(7, 7, zero, "")], [target, slot(8, 8, nil, nil)],
            [slot(7, 7, identity.uuid, identity.registryPath)], [target, slot(8, 8, identity.uuid, "other")],
            [slot(8, 8, zero, identity.registryPath)]]
        for slots in invalid {
            XCTAssertNil(matchingExternalRecoverySlot(slots, identity: identity, numericIDHint: 7))
        }
    }
}
