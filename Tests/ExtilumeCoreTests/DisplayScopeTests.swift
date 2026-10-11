import XCTest
@testable import ExtilumeCore

final class DisplayScopeTests: XCTestCase {
    private let internalDisplay = DisplayObservation(identity: .builtIn, isOnline: true, isActive: true, isMirrored: false)

    func testRejectsEmptyTopology() {
        XCTAssertTrue(assessScope([]).issues.contains(.noDisplay))
    }

    func testRejectsTopologyWithoutExternalDisplay() {
        XCTAssertTrue(assessScope([internalDisplay]).issues.contains(.noExternalDisplay))
    }

    func testRejectsMirroredTopology() {
        let external = DisplayObservation(identity: .physical, isOnline: true, isActive: true, isMirrored: true)
        XCTAssertTrue(assessScope([internalDisplay, external]).issues.contains(.mirrored))
    }

    func testRejectsMultipleExternalDisplays() {
        let first = DisplayObservation(identity: .physical, isOnline: true, isActive: true, isMirrored: false)
        let second = first
        XCTAssertTrue(assessScope([internalDisplay, first, second]).issues.contains(.multipleExternalDisplays))
    }

    func testRejectsVirtualExternalDisplay() {
        let external = DisplayObservation(identity: .virtual, isOnline: true, isActive: true, isMirrored: false)
        XCTAssertTrue(assessScope([internalDisplay, external]).issues.contains(.virtualExternalDisplay))
    }

    func testRejectsUnknownExternalIdentity() {
        let external = DisplayObservation(identity: .unknown, isOnline: true, isActive: true, isMirrored: false)
        XCTAssertTrue(assessScope([internalDisplay, external]).issues.contains(.unknownExternalIdentity))
    }

    func testRejectsOfflineExternalDisplay() {
        let external = DisplayObservation(identity: .physical, isOnline: false, isActive: true, isMirrored: false)
        XCTAssertTrue(assessScope([internalDisplay, external]).issues.contains(.externalNotOnline))
    }

    func testRejectsInactiveExternalDisplay() {
        let external = DisplayObservation(identity: .physical, isOnline: true, isActive: false, isMirrored: false)
        XCTAssertTrue(assessScope([internalDisplay, external]).issues.contains(.externalNotActive))
    }

    func testAcceptsOneOnlineActiveConfirmedPhysicalExternalDisplay() {
        let external = DisplayObservation(identity: .physical, isOnline: true, isActive: true, isMirrored: false)
        XCTAssertTrue(assessScope([internalDisplay, external]).isSupported)
    }
}

final class PhysicalHDMIDisplayMatchTests: XCTestCase {
    private let location = "IOService:/fixture/hdmi"
    private let validDisplayUUID = "11111111-2222-4333-8444-555555555555"
    private let validCandidate = DisplayRegistryEvidence(
        downstream: "HDMI",
        registryPath: "IOService:/fixture/hdmi",
        edidUUID: "fixture-edid-identity"
    )

    func testMatchesUniqueHDMIPathAndValidDisplayUUID() {
        XCTAssertEqual(
            matchPhysicalHDMIDisplayUUID(
                location: location,
                displayUUID: validDisplayUUID,
                candidates: [validCandidate]
            ),
            UUID(uuidString: validDisplayUUID)
        )
    }

    func testRejectsMissingOrInvalidDisplayUUID() {
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: nil, candidates: [validCandidate]))
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: "invalid", candidates: [validCandidate]))
    }

    func testRejectsMissingLocationOrEDIDIdentity() {
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: nil, displayUUID: validDisplayUUID, candidates: [validCandidate]))
        let missingEDID = DisplayRegistryEvidence(downstream: "HDMI", registryPath: location, edidUUID: nil)
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: validDisplayUUID, candidates: [missingEDID]))
        let missingPath = DisplayRegistryEvidence(downstream: "HDMI", registryPath: nil, edidUUID: "fixture-edid-identity")
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: validDisplayUUID, candidates: [validCandidate, missingPath]))
    }

    func testRejectsNonHDMIAndDuplicateRegistryPaths() {
        let nonHDMI = DisplayRegistryEvidence(downstream: "USB-C", registryPath: location, edidUUID: "fixture-edid-identity")
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: validDisplayUUID, candidates: [nonHDMI]))
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: validDisplayUUID, candidates: [validCandidate, validCandidate]))
    }

    func testRejectsUnmatchedRegistryPath() {
        let otherPath = DisplayRegistryEvidence(downstream: "HDMI", registryPath: "IOService:/fixture/other", edidUUID: "fixture-edid-identity")
        XCTAssertNil(matchPhysicalHDMIDisplayUUID(location: location, displayUUID: validDisplayUUID, candidates: [otherPath]))
    }
}
