import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalDisplayStateTests: XCTestCase {
    private let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    private let otherIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!

    private func state(
        id: UInt32,
        identityUUID: UUID? = nil,
        isBuiltIn: Bool = true,
        isOnline: Bool = true,
        isActive: Bool = true,
        hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
        reportedIdentityUUID: UUID? = nil
    ) -> InternalDisplayState {
        InternalDisplayState(
            id: id,
            identityUUID: identityUUID ?? identity,
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

    func testMatchesActiveInternalDisplay() throws {
        let expected = state(id: 7)

        let actual = try matchInternalDisplay(identity: identity, candidates: [7]) { id in
            XCTAssertEqual(id, 7)
            return expected
        }

        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.isEnabled)
    }

    func testSuccessfulMatchDoesNotEmitDiagnostic() throws {
        let expected = state(id: 7)
        var failures: [InternalDisplayIdentityFailure] = []

        let actual = try matchInternalDisplay(
            identity: identity,
            candidates: [7],
            diagnostic: { failures.append($0) }
        ) { _ in expected }

        XCTAssertEqual(actual, expected)
        XCTAssertTrue(failures.isEmpty)
    }

    func testMatchesRequiresNonzeroBuiltInDisplayWithSameIdentity() {
        XCTAssertTrue(state(id: 7).matches(identity: identity))
        XCTAssertFalse(state(id: 0).matches(identity: identity))
        XCTAssertFalse(state(id: 8, isBuiltIn: false).matches(identity: identity))
        XCTAssertFalse(state(id: 9, identityUUID: otherIdentity).matches(identity: identity))
    }

    func testMatchesInactiveOrOfflineInternalDisplayWithoutTreatingItAsEnabled() throws {
        for expected in [state(id: 8, isActive: false), state(id: 9, isOnline: false)] {
            let actual = try matchInternalDisplay(identity: identity, candidates: [expected.id]) { _ in expected }
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(actual.isEnabled)
        }
    }

    func testOldNumericHintDoesNotOverrideIdentityAtNewID() throws {
        let expected = state(id: 42)
        var readIDs: [UInt32] = []

        let actual = try matchInternalDisplay(identity: identity, candidates: [7, 42, 7]) { id in
            readIDs.append(id)
            return id == 7 ? state(id: 7, identityUUID: otherIdentity) : expected
        }

        XCTAssertEqual(readIDs, [7, 42])
        XCTAssertEqual(actual, expected)
    }

    func testUnknownAndUnmatchedCandidatesThrowIdentityConflict() {
        assertIdentityConflict(try matchInternalDisplay(identity: identity, candidates: []) { _ in nil })
        assertIdentityConflict(try matchInternalDisplay(identity: identity, candidates: [4]) { _ in nil })
        assertIdentityConflict(try matchInternalDisplay(identity: identity, candidates: [4]) { _ in
            self.state(id: 4, identityUUID: self.otherIdentity)
        })
    }

    func testPhysicalDisplayWithSameUUIDIsNotAcceptedAsInternal() {
        assertIdentityConflict(try matchInternalDisplay(identity: identity, candidates: [5]) { _ in
            self.state(id: 5, isBuiltIn: false)
        })
    }

    func testDuplicateUUIDMatchesAreConflicted() {
        assertIdentityConflict(try matchInternalDisplay(identity: identity, candidates: [5, 6]) { id in
            self.state(id: id)
        })
    }

    func testNumericIDMismatchIsConflicted() {
        var failures: [InternalDisplayIdentityFailure] = []

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [5],
            diagnostic: { failures.append($0) }
        ) { _ in
            self.state(id: 6)
        })
        XCTAssertEqual(failures, [.numericIDMismatch])
    }

    func testZeroCandidateIsRejectedBeforeAnyRead() {
        var readCount = 0
        var failures: [InternalDisplayIdentityFailure] = []

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [5, 0],
            diagnostic: { failures.append($0) }
        ) { _ in
            readCount += 1
            return nil
        })
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(failures, [.invalidCandidate])
    }

    func testNoMatchAndAmbiguousMatchHaveDistinctDiagnostics() {
        var noMatchFailures: [InternalDisplayIdentityFailure] = []
        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [4],
            diagnostic: { noMatchFailures.append($0) }
        ) { _ in
            self.state(id: 4, identityUUID: self.otherIdentity)
        })
        XCTAssertEqual(noMatchFailures, [.noMatch])

        var ambiguousFailures: [InternalDisplayIdentityFailure] = []
        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [4, 5],
            diagnostic: { ambiguousFailures.append($0) }
        ) { id in
            self.state(id: id)
        })
        XCTAssertEqual(ambiguousFailures, [.ambiguousMatch])
    }

    func testDuplicateReportedIdentityHasDistinctDiagnostic() {
        var failures: [InternalDisplayIdentityFailure] = []

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [4, 5],
            diagnostic: { failures.append($0) }
        ) { id in
            self.state(
                id: id,
                identityUUID: id == 4 ? self.identity : self.otherIdentity,
                reportedIdentityUUID: self.otherIdentity
            )
        })
        XCTAssertEqual(failures, [.duplicateReportedIdentity])
    }

    func testNotBuiltInDisplayHasDistinctDiagnostic() {
        var failures: [InternalDisplayIdentityFailure] = []

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            candidates: [5],
            diagnostic: { failures.append($0) }
        ) { _ in
            self.state(id: 5, isBuiltIn: false)
        })
        XCTAssertEqual(failures, [.notBuiltIn])
    }

    func testHardwareMismatchAndMissingReportedIdentityHaveDistinctDiagnostics() {
        let proof = InternalDisplayHardwareIdentity(bootSession: identity, registryEntryID: 42)
        let otherProof = InternalDisplayHardwareIdentity(bootSession: identity, registryEntryID: 43)
        var mismatchFailures: [InternalDisplayIdentityFailure] = []

        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: proof,
            candidates: [5],
            diagnostic: { mismatchFailures.append($0) }
        ) { _ in
            self.state(
                id: 5,
                hardwareIdentity: otherProof,
                reportedIdentityUUID: self.identity
            )
        })
        XCTAssertEqual(mismatchFailures, [.hardwareMismatch])

        var missingReportedFailures: [InternalDisplayIdentityFailure] = []
        assertIdentityConflict(try matchInternalDisplay(
            identity: identity,
            hardwareIdentity: proof,
            candidates: [6],
            diagnostic: { missingReportedFailures.append($0) }
        ) { _ in
            self.state(
                id: 6,
                identityUUID: self.otherIdentity,
                hardwareIdentity: proof
            )
        })
        XCTAssertEqual(missingReportedFailures, [.missingReportedIdentity])
    }

    func testReadErrorPropagates() {
        enum ReadError: Error, Equatable { case failed }
        var failures: [InternalDisplayIdentityFailure] = []

        XCTAssertThrowsError(try matchInternalDisplay(
            identity: identity,
            candidates: [5],
            diagnostic: { failures.append($0) }
        ) { _ in
            throw ReadError.failed
        }) {
            XCTAssertEqual($0 as? ReadError, .failed)
        }
        XCTAssertTrue(failures.isEmpty)
    }

    func testCodableRoundTrip() throws {
        let expected = state(id: 42, isOnline: false, isActive: true)
        let data = try JSONEncoder().encode(expected)
        let actual = try JSONDecoder().decode(InternalDisplayState.self, from: data)

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isEnabled)
    }
}
