import ExtilumeCore
import Darwin
import Foundation

struct LayoutCloseoutFileReference: Codable {
    let path: String
    let sha256: String
}

struct LayoutResidualCloseoutProof: Codable {
    let files: [String: LayoutCloseoutFileReference]
}

struct LayoutResidualCloseoutRequest: Codable {
    let authorization: LayoutCloseoutRequest
    let proof: LayoutResidualCloseoutProof
}

private final class CloseoutReadOnlyFile {
    let directory: LayoutCloseoutDirectory
    let name: String
    let bytes: Data
    let device: Int64
    let inode: UInt64

    init(_ reference: LayoutCloseoutFileReference) throws {
        let url = URL(fileURLWithPath: reference.path)
        guard reference.path.hasPrefix("/"), !reference.path.split(separator: "/").contains("..") else {
            throw LayoutCloseoutError.storage
        }
        directory = try LayoutCloseoutDirectory(url.deletingLastPathComponent().path)
        name = url.lastPathComponent
        let read = try directory.readBound(name)
        guard layoutCloseoutSHA256(read.bytes) == reference.sha256 else { throw LayoutCloseoutError.storage }
        (bytes, device, inode) = read
    }

    func verify() throws {
        let current = try directory.readBound(name)
        guard current.bytes == bytes, current.device == device, current.inode == inode else {
            throw LayoutCloseoutError.storage
        }
    }
}

final class LayoutResidualCloseoutBinding {
    private let files: [CloseoutReadOnlyFile]
    private let credential: CloseoutReadOnlyFile

    init(_ proof: LayoutResidualCloseoutProof, request: LayoutCloseoutRequest) throws {
        let roles = ["previousRequest", "attempt", "stopped", "old-1-original", "old-2-original",
                     "old-1-restored", "old-1-verified", "independentSummary"]
        guard Set(proof.files.keys) == Set(roles), request.records.count == 1 else {
            throw LayoutCloseoutError.authorization
        }
        let bound = try roles.map { try CloseoutReadOnlyFile(proof.files[$0]!) }
        files = bound
        let decoder = JSONDecoder()
        let previous = try decoder.decode(LayoutCloseoutRequest.self, from: bound[0].bytes)
        // Historical approval is checked at its original time, never reused as current authorization.
        try previous.validate(now: previous.observedAtNanoseconds, probeSHA256: previous.probeSHA256)
        let target = request.records[0]
        let old1 = previous.records[0]
        let old2 = previous.records[1]
        guard request.candidate != previous.candidate,
              target.role == old2.role, target.directory == old2.directory,
              target.device == old2.device, target.inode == old2.inode,
              target.originalSHA256 == old2.originalSHA256,
              target.session == old2.session, target.generation == old2.generation,
              old1.device != target.device || old1.inode != target.inode,
              request.evidenceDirectory != previous.evidenceDirectory else { throw LayoutCloseoutError.authorization }
        for index in 1...6 {
            guard bound[index].directory.url.path == URL(fileURLWithPath: previous.evidenceDirectory).path,
                  bound[index].name == roles[index] + ".json" else { throw LayoutCloseoutError.storage }
        }
        struct Attempt: Decodable { let candidate: UUID; let requestSHA256: String }
        let attempt = try decoder.decode(Attempt.self, from: bound[1].bytes)
        guard attempt.candidate == previous.candidate,
              attempt.requestSHA256 == layoutCloseoutSHA256(bound[0].bytes) else { throw LayoutCloseoutError.storage }
        let stopped = try decoder.decode(LayoutCloseoutStoppedReceipt.self, from: bound[2].bytes)
        guard stopped.verifiedRoles == ["old-1"] else { throw LayoutCloseoutError.storage }
        let original1 = try decoder.decode(RecoveryRecord.self, from: bound[3].bytes)
        let original2 = try decoder.decode(RecoveryRecord.self, from: bound[4].bytes)
        try original1.validate()
        try original2.validate()
        guard layoutCloseoutSHA256(bound[3].bytes) == old1.originalSHA256,
              layoutCloseoutSHA256(bound[4].bytes) == target.originalSHA256,
              original1.session == old1.session, original1.generation == old1.generation,
              original2.session == target.session, original2.generation == target.generation else {
            throw LayoutCloseoutError.storage
        }
        _ = try original2.confirmingLayoutCloseout(actual: request.expectedC.layout())
        let restored = try decoder.decode(RecoveryRecord.self, from: bound[5].bytes)
        try restored.validate()
        guard restored.canClear, restored.internalDisplay == nil, restored.externalDisplay == nil,
              restored == (try original1.confirmingLayoutCloseout(actual: previous.expectedC.layout())),
              previous.expectedC.displays.count == request.expectedC.displays.count else { throw LayoutCloseoutError.storage }
        for prior in previous.expectedC.displays {
            guard let current = request.expectedC.displays.first(where: { $0.identityUUID == prior.identityUUID }),
                  current.identity == prior.identity, current.isOnline == prior.isOnline,
                  current.isActive == prior.isActive, current.isMain == prior.isMain,
                  current.isMirrored == prior.isMirrored, current.originX == prior.originX,
                  current.originY == prior.originY, current.width == prior.width, current.height == prior.height,
                  current.rotation == prior.rotation, current.mode == prior.mode else { throw LayoutCloseoutError.observation }
        }
        struct Verified: Decodable { let beforeSHA256: String; let afterSHA256: String; let session: UUID; let generation: String }
        let verified = try decoder.decode(Verified.self, from: bound[6].bytes)
        guard verified.beforeSHA256 == old1.originalSHA256,
              verified.afterSHA256 == layoutCloseoutSHA256(bound[5].bytes),
              verified.session == old1.session, verified.generation == String(old1.generation) else { throw LayoutCloseoutError.storage }
        struct IndependentSummary: Decodable {
            struct Record: Decodable {
                let role: String
                let phase: String
                let layoutPending: Bool
                let originalBackupMatchesApproval: Bool
                let sessionGenerationPreserved: Bool
                let directoryIdentityPreserved: Bool
                let bytesUnchanged: Bool
                let unchangedOtherRecordFields: Bool?
                let baselineIsAuthorizedC: Bool?
                let savedBytesAndHashVerified: Bool?
                let noPendingResponsibility: Bool?
            }
            let records: [Record]
            let readOnly: Bool
            let closeoutExitCode: Int
            let retryPerformed: Bool
            let rollbackPerformed: Bool
            let recoveryRecordWrites: Int
            let hardwareChecksPassed: Bool
            let bothSnapshotsEqualAuthorizedC: Bool
            let sameBoot: Bool
            let internalIdentityMatches: Bool
            let completeReceiptAbsent: Bool
            let bothOriginalBackupsPreserved: Bool
            let old1CloseoutIndependentlyVerified: Bool
            let old2UnchangedPending: Bool
            let stopped: LayoutCloseoutStoppedReceipt
        }
        let summary = try decoder.decode(IndependentSummary.self, from: bound[7].bytes)
        guard summary.readOnly, summary.closeoutExitCode != 0, !summary.retryPerformed, !summary.rollbackPerformed,
              summary.recoveryRecordWrites == 0, summary.hardwareChecksPassed, summary.bothSnapshotsEqualAuthorizedC,
              summary.sameBoot, summary.internalIdentityMatches, summary.completeReceiptAbsent,
              summary.bothOriginalBackupsPreserved, summary.old1CloseoutIndependentlyVerified, summary.old2UnchangedPending,
              summary.stopped.verifiedRoles == stopped.verifiedRoles, summary.stopped.stage == stopped.stage,
              summary.stopped.failureCode == stopped.failureCode else { throw LayoutCloseoutError.storage }
        guard summary.records.map(\.role) == ["old-1", "old-2"],
              summary.records.allSatisfy({ $0.originalBackupMatchesApproval && $0.sessionGenerationPreserved && $0.directoryIdentityPreserved }),
              summary.records[0].phase == "restored", !summary.records[0].layoutPending,
              summary.records[0].unchangedOtherRecordFields == true, summary.records[0].baselineIsAuthorizedC == true,
              summary.records[0].savedBytesAndHashVerified == true, summary.records[0].noPendingResponsibility == true,
              summary.records[1].phase == "owned", summary.records[1].layoutPending, summary.records[1].bytesUnchanged else {
            throw LayoutCloseoutError.storage
        }
        credential = try CloseoutReadOnlyFile(.init(
            path: URL(fileURLWithPath: old1.directory).appendingPathComponent("recovery-record.json").path,
            sha256: verified.afterSHA256))
        try credential.directory.verify(device: old1.device, inode: old1.inode)
        let targetDirectory = try LayoutCloseoutDirectory(target.directory)
        try targetDirectory.verify(device: target.device, inode: target.inode)
        let targetFile = try targetDirectory.readBound("recovery-record.json")
        guard credential.bytes == bound[5].bytes, targetFile.bytes == bound[4].bytes,
              credential.device != targetFile.device || credential.inode != targetFile.inode else { throw LayoutCloseoutError.storage }
        try verify()
    }

    func verify() throws {
        for file in files { try file.verify() }
        try credential.verify()
        try files[1].directory.requireAbsent("complete.json")
    }

    func verifyEvidenceDirectory(_ evidence: LayoutCloseoutDirectory, target: LayoutCloseoutEntry) throws {
        var output = stat()
        guard fstat(evidence.descriptor, &output) == 0,
              Int64(output.st_dev) != target.device || output.st_ino != target.inode else { throw LayoutCloseoutError.storage }
        for directory in files.map(\.directory) + [credential.directory] {
            var input = stat()
            guard fstat(directory.descriptor, &input) == 0,
                  input.st_dev != output.st_dev || input.st_ino != output.st_ino else { throw LayoutCloseoutError.storage }
        }
    }
}
