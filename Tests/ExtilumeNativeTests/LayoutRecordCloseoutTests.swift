import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class LayoutRecordCloseoutTests: XCTestCase {
    private let inner = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let outer = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let bootID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    private let time: UInt64 = 100_000_000_000
    private let sha = String(repeating: "a", count: 64)
    private enum Failure: Error { case injected }

    private var hardware: InternalDisplayHardwareIdentity { .init(bootSession: bootID, registryEntryID: 42) }
    private var snapshot: Snapshot {
        let mode = DisplayModeState(width: 100, height: 100, pixelWidth: 100, pixelHeight: 100, refreshRate: 60, ioDisplayModeID: 1)
        return Snapshot(displays: [
            DisplayState(id: 1, identity: .builtIn, identityUUID: inner, isOnline: true, isActive: true, isMain: true, isMirrored: false, originX: 0, originY: 0, width: 100, height: 100, rotation: 0, mode: mode),
            DisplayState(id: 2, identity: .physical, identityUUID: outer, isOnline: true, isActive: true, isMain: false, isMirrored: false, originX: 200, originY: 0, width: 100, height: 100, rotation: 0, mode: mode)
        ])
    }
    private func state(id: UInt32 = 1, reported: UUID? = nil) -> InternalDisplayState {
        InternalDisplayState(id: id, identityUUID: inner, isBuiltIn: true, isOnline: true, isActive: true, hardwareIdentity: hardware, reportedIdentityUUID: reported ?? inner)
    }

    func testSuccessPreservesBothOriginalsAndCompletes() throws {
        try withFixture { request, originals, evidence in
            try run(request)
            for index in 0..<2 {
                XCTAssertEqual(try Data(contentsOf: evidence.appendingPathComponent("old-\(index + 1)-original.json")), originals[index])
                XCTAssertEqual(try RecoveryStore(directory: URL(fileURLWithPath: request.records[index].directory)).load()?.phase, .restored)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
        }
    }

    func testUnapprovedStopsBeforeObservationOrEvidence() throws {
        try withFixture(approved: false) { request, originals, evidence in
            var observed = false
            XCTAssertThrowsError(try run(request, snapshot: { _, _ in observed = true; throw Failure.injected }))
            XCTAssertFalse(observed)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: evidence.path).isEmpty)
            try self.assertOriginals(request, originals)
        }
    }

    func testWrongBootHashAndDirectoryIdentityKeepRecords() throws {
        for variant in 0..<3 {
            try withFixture(badHash: variant == 1, badInode: variant == 2) { request, originals, evidence in
                XCTAssertThrowsError(try run(request, boot: { variant == 0 ? UUID() : self.bootID }))
                try self.assertOriginals(request, originals)
                XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
            }
        }
    }

    func testObservationConflictsKeepRecords() throws {
        for variant in 0..<3 {
            try withFixture { request, originals, _ in
                var calls = 0
                XCTAssertThrowsError(try run(request, snapshot: { _, _ in
                    calls += 1
                    if variant == 0 && calls == 2 { return Snapshot(displays: []) }
                    return self.snapshot
                }, internalState: { _, _, _, _, _ in
                    self.state(id: variant == 1 ? 9 : 1, reported: variant == 2 ? self.outer : self.inner)
                }))
                try self.assertOriginals(request, originals)
            }
        }
    }

    func testSecondRecordFailureLeavesPartialReceiptAndBothBackups() throws {
        try withFixture { request, originals, evidence in
            XCTAssertThrowsError(try run(request, snapshot: { _, _ in
                if FileManager.default.fileExists(atPath: evidence.appendingPathComponent("old-1-verified.json").path) { throw Failure.injected }
                return self.snapshot
            }))
            XCTAssertEqual(try RecoveryStore(directory: URL(fileURLWithPath: request.records[0].directory)).load()?.phase, .restored)
            XCTAssertEqual(try RecoveryStore(directory: URL(fileURLWithPath: request.records[1].directory)).loadWithOriginalBytes()?.bytes, originals[1])
            for index in 0..<2 { XCTAssertEqual(try Data(contentsOf: evidence.appendingPathComponent("old-\(index + 1)-original.json")), originals[index]) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("old-1-verified.json").path))
            let receipt = try stopped(evidence)
            XCTAssertEqual(receipt.verifiedRoles, ["old-1"])
            XCTAssertEqual(receipt.stage, .snapshotFirst)
            XCTAssertEqual(receipt.failureCode, "unclassified")
            XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
        }
    }

    func testEvidenceCannotBeReused() throws {
        try withFixture { request, _, _ in
            try run(request)
            XCTAssertThrowsError(try run(request))
        }
    }

    func testElapsedGapAndDeadlineStopBeforeRecordWrites() throws {
        for elapsed: UInt64 in [3_000_000_001, 30_000_000_000] {
            try withFixture { request, originals, _ in
                var calls = 0
                XCTAssertThrowsError(try run(request, now: {
                    calls += 1
                    return self.time + (calls == 1 ? 0 : elapsed)
                }))
                try self.assertOriginals(request, originals)
            }
        }
    }

    func testLateObservationReceiptStopsBeforeFirstReplacement() throws {
        try withFixture { request, originals, evidence in
            var observationsAtIntent: Int?
            XCTAssertThrowsError(try run(request, now: {
                let names = try FileManager.default.contentsOfDirectory(atPath: evidence.path)
                let count = names.filter { $0.hasPrefix("internal-") }.count
                if names.contains("old-1-save-requested.json") {
                    if let previous = observationsAtIntent, count > previous { return self.time + 4_000_000_000 }
                    observationsAtIntent = count
                }
                return self.time
            }))
            try self.assertOriginals(request, originals)
            XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
        }
    }

    func testLateFinalReceiptCannotReturnSuccess() throws {
        try withFixture { request, _, evidence in
            XCTAssertThrowsError(try run(request, now: {
                FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path)
                    ? self.time + 31_000_000_000 : self.time
            }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("stopped.json").path))
        }
    }

    func testSlowProcessCheckCannotAdmitReplacementOrReturnSuccess() throws {
        for atCommit in [true, false] {
            try withFixture { request, originals, evidence in
                var elapsed: UInt64 = 0
                XCTAssertThrowsError(try run(request, now: { self.time + elapsed }, quiet: {
                    let names = try FileManager.default.contentsOfDirectory(atPath: request.records[0].directory)
                    let final = FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path)
                    if (atCommit && names.contains(where: { $0.hasPrefix(".recovery-backup-") })) || (!atCommit && final) {
                        elapsed = 31_000_000_000
                    }
                }))
                if atCommit { try self.assertOriginals(request, originals) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("stopped.json").path))
            }
        }
    }

    func testDirectoryReplacedAtCommitIsNotWrittenThroughOldDescriptor() throws {
        try withFixture { request, originals, evidence in
            let source = URL(fileURLWithPath: request.records[0].directory)
            let retained = source.appendingPathExtension("retained")
            var moved = false
            XCTAssertThrowsError(try run(request, quiet: {
                guard !moved else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
                if names.contains(where: { $0.hasPrefix(".recovery-backup-") }) {
                    try FileManager.default.moveItem(at: source, to: retained)
                    guard mkdir(source.path, 0o700) == 0 else { throw Failure.injected }
                    moved = true
                }
            }))
            XCTAssertTrue(moved)
            XCTAssertEqual(try RecoveryStore(directory: retained).loadWithOriginalBytes()?.bytes, originals[0])
            XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
        }
    }

    func testStoppedReceiptForOwnershipAndProcessFailures() throws {
        try withFixture { request, originals, evidence in
            let owner = try RecoveryStore(directory: URL(fileURLWithPath: request.records[0].directory))
            try owner.acquireExclusiveOwnership()
            XCTAssertThrowsError(try run(request))
            let receipt = try stopped(evidence)
            XCTAssertEqual(receipt.stage, .ownership)
            XCTAssertEqual(receipt.failureCode, "store-ownership-unavailable")
            XCTAssertEqual(receipt.verifiedRoles, [])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: evidence.path).contains { $0.hasPrefix("observation-") })
            try assertOriginals(request, originals)
            withExtendedLifetime(owner) {}
        }
        try withFixture { request, originals, evidence in
            XCTAssertThrowsError(try run(request, quiet: { throw LayoutCloseoutError.controllerPresent }))
            let receipt = try stopped(evidence)
            XCTAssertEqual(receipt.stage, .processes)
            XCTAssertEqual(receipt.failureCode, "closeout-controllerPresent")
            try assertOriginals(request, originals)
        }
    }

    func testStoppedReceiptDistinguishesWitnessAndValidationFailures() throws {
        for variant in 0..<7 {
            try withFixture { request, originals, evidence in
                var snapshots = 0
                var failBoot = false
                XCTAssertThrowsError(try run(request, boot: { failBoot ? UUID() : self.bootID }, snapshot: { _, check in
                    snapshots += 1
                    if variant == 2 { failBoot = true; try check() }
                    if variant == 6 { try check(); throw SnapshotWitnessError.spawnFailed }
                    if variant == 0 || (variant == 1 && snapshots == 2) { throw SnapshotWitnessError.spawnFailed }
                    if variant == 3 && snapshots == 2 { return Snapshot(displays: []) }
                    return self.snapshot
                }, internalState: { _, _, _, _, _ in
                    if variant == 4 { throw SnapshotWitnessError.spawnFailed }
                    return self.state(id: variant == 5 ? 9 : 1)
                }))
                let receipt = try stopped(evidence)
                let stages: [LayoutCloseoutStage] = [.snapshotFirst, .snapshotSecond, .boot, .layout, .internalWitness, .internalState, .snapshotFirst]
                let codes = ["witness-spawn", "witness-spawn", "closeout-environment", "closeout-observation", "witness-spawn", "closeout-observation", "witness-spawn"]
                XCTAssertEqual(receipt.stage, stages[variant])
                XCTAssertEqual(receipt.failureCode, codes[variant])
                XCTAssertEqual(receipt.verifiedRoles, [])
                try assertOriginals(request, originals)
            }
        }
    }

    func testStoppedReceiptDoesNotSerializeErrorDetails() throws {
        try withFixture { request, _, evidence in
            let sensitive = "synthetic-private-error-detail"
            let error = NSError(domain: sensitive, code: 7, userInfo: [NSLocalizedDescriptionKey: sensitive, "extra": sensitive])
            XCTAssertThrowsError(try run(request, snapshot: { _, _ in throw error }))
            let data = try Data(contentsOf: evidence.appendingPathComponent("stopped.json"))
            let receipt = try JSONDecoder().decode(LayoutCloseoutStoppedReceipt.self, from: data)
            XCTAssertEqual(receipt.stage, .snapshotFirst)
            XCTAssertEqual(receipt.failureCode, "unclassified")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["verifiedRoles", "stage", "failureCode"]))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(sensitive))
        }
    }

    func testResidualSuccessWritesOnlyRemainingRecordAndCannotReplay() throws {
        try withResidualFixture { request, proof, old1, original2 in
            let before = try Data(contentsOf: old1)
            let names = try FileManager.default.contentsOfDirectory(atPath: old1.deletingLastPathComponent().path)
            var identity = stat()
            XCTAssertEqual(lstat(old1.path, &identity), 0)
            try run(request, residualProof: proof)
            XCTAssertEqual(try Data(contentsOf: old1), before)
            var after = stat()
            XCTAssertEqual(lstat(old1.path, &after), 0)
            XCTAssertEqual(identity.st_ino, after.st_ino)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old1.deletingLastPathComponent().path), names)
            let evidence = URL(fileURLWithPath: request.evidenceDirectory)
            XCTAssertEqual(try Data(contentsOf: evidence.appendingPathComponent("old-2-original.json")), original2)
            let saved = try RecoveryStore(directory: URL(fileURLWithPath: request.records[0].directory)).load()
            XCTAssertEqual(saved?.phase, .restored)
            XCTAssertEqual(saved?.session, request.records[0].session)
            XCTAssertEqual(saved?.generation, request.records[0].generation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: evidence.path).contains { $0.hasPrefix("old-1") })
            XCTAssertThrowsError(try run(request, residualProof: proof))
        }
    }

    func testDualEntryRejectsResidualWithoutProofBeforeConsumingAttempt() throws {
        try withResidualFixture { request, _, _, _ in
            XCTAssertThrowsError(try run(request))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: request.evidenceDirectory).isEmpty)
        }
    }

    func testResidualAuthorizationCannotChangeScopeRoleOrApproval() throws {
        for key in ["scope", "records", "approved", "observedAtNanoseconds"] {
            try withResidualFixture { request, proof, _, original2 in
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
                switch key {
                case "scope": object[key] = "legacy-layout-record-closeout-v1"
                case "records":
                    var records = try XCTUnwrap(object[key] as? [[String: Any]])
                    records[0]["role"] = "old-1"
                    object[key] = records
                case "approved": object[key] = false
                default: object[key] = time + 1
                }
                let changed = try JSONDecoder().decode(LayoutCloseoutRequest.self, from: JSONSerialization.data(withJSONObject: object))
                XCTAssertThrowsError(try run(changed, residualProof: proof))
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: request.evidenceDirectory).isEmpty)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
            }
        }
    }

    func testResidualCannotWriteEvidenceIntoCredentialDirectory() throws {
        try withResidualFixture { request, proof, old1, _ in
            let directory = old1.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            object["evidenceDirectory"] = directory.path
            let changed = try JSONDecoder().decode(LayoutCloseoutRequest.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try run(changed, residualProof: proof))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), names)
        }
    }

    func testResidualRejectsEveryMismatchedHistoricalReference() throws {
        for role in ["previousRequest", "attempt", "stopped", "old-1-original", "old-2-original", "old-1-restored", "old-1-verified", "independentSummary"] {
            try withResidualFixture { request, proof, old1, original2 in
                let before = try Data(contentsOf: old1)
                var files = proof.files
                files[role] = .init(path: try XCTUnwrap(files[role]).path, sha256: sha)
                XCTAssertThrowsError(try run(request, residualProof: .init(files: files)))
                XCTAssertEqual(try Data(contentsOf: old1), before)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
            }
        }
    }

    func testResidualRejectsChangedCredentialBeforeOrAfterTargetSave() throws {
        for afterSave in [false, true] {
            try withResidualFixture { request, proof, old1, original2 in
                let evidence = URL(fileURLWithPath: request.evidenceDirectory)
                var changed = false
                XCTAssertThrowsError(try run(request, residualProof: proof, quiet: {
                    if !changed && (!afterSave || FileManager.default.fileExists(atPath: evidence.appendingPathComponent("old-2-verified.json").path)) {
                        try Data("changed".utf8).write(to: old1)
                        changed = true
                    }
                }))
                XCTAssertTrue(changed)
                XCTAssertEqual(try Data(contentsOf: old1), Data("changed".utf8), "Must not repair or roll back the credential")
                let bytes = try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json"))
                if afterSave { XCTAssertEqual(try JSONDecoder().decode(RecoveryRecord.self, from: bytes).phase, .restored) }
                else { XCTAssertEqual(bytes, original2) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("complete.json").path))
            }
        }
    }

    func testResidualRejectsSemanticallyInvalidProofEvenWithMatchingHashes() throws {
        for role in ["attempt", "stopped", "old-1-verified", "independentSummary"] {
            try withResidualFixture { request, proof, old1, original2 in
                let credential = try Data(contentsOf: old1)
                let changed = try rewriting(proof, role: role) { object in
                    switch role {
                    case "attempt": object["candidate"] = UUID().uuidString
                    case "stopped": object["verifiedRoles"] = ["old-2"]
                    case "old-1-verified": object["session"] = UUID().uuidString
                    default: object["old1CloseoutIndependentlyVerified"] = false
                    }
                }
                XCTAssertThrowsError(try run(request, residualProof: changed))
                XCTAssertEqual(try Data(contentsOf: old1), credential)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
            }
        }
    }

    func testResidualProofComparesUUIDSemantically() throws {
        try withResidualFixture { request, proof, _, _ in
            var changed = try rewriting(proof, role: "attempt") { object in
                object["candidate"] = (object["candidate"] as? String)?.lowercased()
            }
            changed = try rewriting(changed, role: "old-1-verified") { object in
                object["session"] = (object["session"] as? String)?.lowercased()
            }
            try run(request, residualProof: changed)
        }
    }

    func testResidualRejectsMutatedTargetAndChangedPriorProofAtCommit() throws {
        for mutateTarget in [true, false] {
            try withResidualFixture { request, proof, old1, original2 in
                let credential = try Data(contentsOf: old1)
                var changed = false
                XCTAssertThrowsError(try run(request, residualProof: proof, quiet: {
                    guard !changed else { return }
                    let names = try FileManager.default.contentsOfDirectory(atPath: request.records[0].directory)
                    guard names.contains(where: { $0.hasPrefix(".recovery-backup-") }) else { return }
                    if mutateTarget {
                        let url = URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")
                        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original2) as? [String: Any])
                        object["generation"] = request.records[0].generation + 1
                        try JSONSerialization.data(withJSONObject: object).write(to: url)
                    } else {
                        let path = try XCTUnwrap(proof.files["independentSummary"]).path
                        try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
                    }
                    changed = true
                }))
                XCTAssertTrue(changed)
                XCTAssertEqual(try Data(contentsOf: old1), credential)
                let saved = try RecoveryStore(directory: URL(fileURLWithPath: request.records[0].directory)).load()
                XCTAssertEqual(saved?.phase, .owned)
                XCTAssertFalse(FileManager.default.fileExists(atPath: request.evidenceDirectory + "/complete.json"))
            }
        }
    }

    private func rewriting(_ proof: LayoutResidualCloseoutProof, role: String,
                           edit: (inout [String: Any]) throws -> Void) throws -> LayoutResidualCloseoutProof {
        let url = URL(fileURLWithPath: try XCTUnwrap(proof.files[role]).path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try edit(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: url)
        var files = proof.files
        files[role] = .init(path: url.path, sha256: layoutCloseoutSHA256(bytes))
        return .init(files: files)
    }

    func testResidualRejectsCredentialInodeReplacementEvenWithIdenticalBytes() throws {
        try withResidualFixture { request, proof, old1, original2 in
            var replaced = false
            XCTAssertThrowsError(try run(request, residualProof: proof, quiet: {
                guard !replaced else { return }
                let bytes = try Data(contentsOf: old1)
                try bytes.write(to: old1, options: .atomic)
                XCTAssertEqual(chmod(old1.path, 0o600), 0)
                replaced = true
            }))
            XCTAssertTrue(replaced)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
        }
    }

    func testResidualRejectsTargetOwnershipConflictAndSymbolicCredential() throws {
        for linked in [false, true] {
            try withResidualFixture { request, proof, old1, original2 in
                let owner = try RecoveryStore(directory: URL(fileURLWithPath: request.records[0].directory))
                if linked {
                    let retained = old1.appendingPathExtension("retained")
                    try FileManager.default.moveItem(at: old1, to: retained)
                    try FileManager.default.createSymbolicLink(at: old1, withDestinationURL: retained)
                } else { try owner.acquireExclusiveOwnership() }
                XCTAssertThrowsError(try run(request, residualProof: proof))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
                withExtendedLifetime(owner) {}
            }
        }
    }

    func testResidualObservationAndBackupFailuresLeaveTargetUnchanged() throws {
        for variant in 0..<3 {
            try withResidualFixture { request, proof, _, original2 in
                let evidence = try LayoutCloseoutDirectory(request.evidenceDirectory)
                if variant == 2 { try evidence.write("old-2-original.json", data: Data()) }
                XCTAssertThrowsError(try run(request, residualProof: proof,
                    snapshot: { _, _ in variant == 0 ? Snapshot(displays: []) : self.snapshot },
                    internalState: { _, _, _, _, _ in self.state(id: variant == 1 ? 9 : 1) }))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json")), original2)
            }
        }
    }

    func testResidualRejectsLateCommitAndLateCompletion() throws {
        for atCommit in [true, false] {
            try withResidualFixture { request, proof, old1, original2 in
                let credential = try Data(contentsOf: old1)
                var elapsed: UInt64 = 0
                XCTAssertThrowsError(try run(request, now: { self.time + elapsed }, residualProof: proof, quiet: {
                    let names = try FileManager.default.contentsOfDirectory(atPath: request.records[0].directory)
                    if atCommit ? names.contains(where: { $0.hasPrefix(".recovery-backup-") })
                        : FileManager.default.fileExists(atPath: request.evidenceDirectory + "/complete.json") {
                        elapsed = 31_000_000_000
                    }
                }))
                XCTAssertEqual(try Data(contentsOf: old1), credential)
                let bytes = try Data(contentsOf: URL(fileURLWithPath: request.records[0].directory).appendingPathComponent("recovery-record.json"))
                if atCommit { XCTAssertEqual(bytes, original2) }
                else { XCTAssertEqual(try JSONDecoder().decode(RecoveryRecord.self, from: bytes).phase, .restored) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: request.evidenceDirectory + "/stopped.json"))
            }
        }
    }

    private func withResidualFixture(_ body: (LayoutCloseoutRequest, LayoutResidualCloseoutProof, URL, Data) throws -> Void) throws {
        try withFixture { previous, originals, evidence in
            XCTAssertThrowsError(try run(previous, snapshot: { _, _ in
                if FileManager.default.fileExists(atPath: evidence.appendingPathComponent("old-1-verified.json").path) { throw Failure.injected }
                return self.snapshot
            }))
            let root = evidence.deletingLastPathComponent()
            let output = root.appendingPathComponent("residual-evidence")
            XCTAssertEqual(mkdir(output.path, 0o700), 0)
            let priorInput = root.appendingPathComponent("previous.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try LayoutCloseoutDirectory(root.path).write(priorInput.lastPathComponent, data: encoder.encode(previous))
            let stopped = try self.stopped(evidence)
            let summary: [String: Any] = ["readOnly": true, "closeoutExitCode": 1, "retryPerformed": false,
                "rollbackPerformed": false, "recoveryRecordWrites": 0, "hardwareChecksPassed": true,
                "bothSnapshotsEqualAuthorizedC": true, "sameBoot": true, "internalIdentityMatches": true,
                "completeReceiptAbsent": true, "bothOriginalBackupsPreserved": true,
                "old1CloseoutIndependentlyVerified": true, "old2UnchangedPending": true,
                "stopped": ["verifiedRoles": stopped.verifiedRoles, "stage": stopped.stage.rawValue, "failureCode": stopped.failureCode],
                "records": [
                    ["role": "old-1", "phase": "restored", "layoutPending": false, "bytesUnchanged": false,
                     "originalBackupMatchesApproval": true, "sessionGenerationPreserved": true, "directoryIdentityPreserved": true,
                     "unchangedOtherRecordFields": true, "baselineIsAuthorizedC": true, "savedBytesAndHashVerified": true, "noPendingResponsibility": true],
                    ["role": "old-2", "phase": "owned", "layoutPending": true, "bytesUnchanged": true,
                     "originalBackupMatchesApproval": true, "sessionGenerationPreserved": true, "directoryIdentityPreserved": true]]]
            let summaryURL = root.appendingPathComponent("summary.json")
            try LayoutCloseoutDirectory(root.path).write(summaryURL.lastPathComponent, data: JSONSerialization.data(withJSONObject: summary))
            var paths = ["previousRequest": priorInput, "independentSummary": summaryURL]
            for role in ["attempt", "stopped", "old-1-original", "old-2-original", "old-1-restored", "old-1-verified"] {
                paths[role] = evidence.appendingPathComponent(role + ".json")
            }
            let files = try paths.mapValues { LayoutCloseoutFileReference(path: $0.path, sha256: layoutCloseoutSHA256(try Data(contentsOf: $0))) }
            let request = LayoutCloseoutRequest(scope: "legacy-layout-residual-closeout-v1", candidate: UUID(), approved: true,
                adoptCurrentC: true, physicalObservationConfirmed: true, observedAtNanoseconds: time, probeSHA256: sha,
                internalHardwareIdentity: hardware, expectedC: snapshot, records: [previous.records[1]], evidenceDirectory: output.path)
            let old1 = URL(fileURLWithPath: previous.records[0].directory).appendingPathComponent("recovery-record.json")
            try body(request, .init(files: files), old1, originals[1])
        }
    }

    private func stopped(_ evidence: URL) throws -> LayoutCloseoutStoppedReceipt {
        try JSONDecoder().decode(LayoutCloseoutStoppedReceipt.self, from: Data(contentsOf: evidence.appendingPathComponent("stopped.json")))
    }

    private func run(_ request: LayoutCloseoutRequest, now: (() throws -> UInt64)? = nil, boot: (() throws -> UUID)? = nil,
                     residualProof: LayoutResidualCloseoutProof? = nil,
                     quiet: @escaping () throws -> Void = {},
                     snapshot: ((UInt64, () throws -> Void) throws -> Snapshot)? = nil,
                     internalState: ((UUID, UInt32, InternalDisplayHardwareIdentity, UInt64, () throws -> Void) throws -> InternalDisplayState)? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try performLayoutRecordCloseout(request: request, requestBytes: encoder.encode(request), executableSHA256: sha,
            residualProof: residualProof,
            now: now ?? { self.time }, boot: boot ?? { self.bootID }, quiet: quiet,
            snapshot: snapshot ?? { _, _ in self.snapshot }, internalState: internalState ?? { _, _, _, _, _ in self.state() })
    }

    private func assertOriginals(_ request: LayoutCloseoutRequest, _ originals: [Data]) throws {
        for index in 0..<2 {
            XCTAssertEqual(try RecoveryStore(directory: URL(fileURLWithPath: request.records[index].directory)).loadWithOriginalBytes()?.bytes, originals[index])
        }
    }

    private func withFixture(approved: Bool = true, badHash: Bool = false, badInode: Bool = false,
                             _ body: (LayoutCloseoutRequest, [Data], URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/extilume-closeout-native-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.injected }
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = root.appendingPathComponent("evidence")
        guard mkdir(evidence.path, 0o700) == 0 else { throw Failure.injected }
        var entries: [LayoutCloseoutEntry] = []
        var originals: [Data] = []
        for index in 0..<2 {
            let directory = root.appendingPathComponent("record-\(index)")
            guard mkdir(directory.path, 0o700) == 0 else { throw Failure.injected }
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let old = try DisplayLayout(main: inner, origins: [inner: .init(x: 0, y: 0), outer: .init(x: 100, y: 0)])
            let applied = try DisplayLayout(main: inner, origins: [inner: .init(x: 0, y: 0), outer: .init(x: -100, y: 0)])
            var record = try RecoveryRecord(baseline: old, target: applied)
            try record.confirmApplied(applied)
            try store.save(record)
            let bytes = try XCTUnwrap(store.loadWithOriginalBytes()?.bytes)
            originals.append(bytes)
            var info = stat()
            guard lstat(directory.path, &info) == 0 else { throw Failure.injected }
            entries.append(LayoutCloseoutEntry(role: "old-\(index + 1)", directory: directory.path, device: Int64(info.st_dev), inode: info.st_ino + (badInode && index == 0 ? 1 : 0), originalSHA256: badHash && index == 0 ? sha : layoutCloseoutSHA256(bytes), session: record.session, generation: record.generation))
        }
        let request = LayoutCloseoutRequest(scope: "legacy-layout-record-closeout-v1", candidate: UUID(), approved: approved, adoptCurrentC: true, physicalObservationConfirmed: true, observedAtNanoseconds: time, probeSHA256: sha, internalHardwareIdentity: hardware, expectedC: snapshot, records: entries, evidenceDirectory: evidence.path)
        try body(request, originals, evidence)
    }
}
