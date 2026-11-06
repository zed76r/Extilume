import CryptoKit
import Darwin
import ExtilumeCore
import Foundation

enum LayoutCloseoutError: String, Error {
    case authorization, environment, observation, storage, controllerPresent
    case processListSizing, processListRead, processImageUnavailable
}

enum LayoutCloseoutStage: String, Codable {
    case records, ownership, sourceIdentity, clock, boot, evidence, processes
    case snapshotFirst, snapshotSecond, layout, internalWitness, internalState, observationReceipt
    case recordBinding, backup, save, saveIntent, savedRecord, finalVerification, completion
}

struct LayoutCloseoutStoppedReceipt: Codable {
    let verifiedRoles: [String]
    let stage: LayoutCloseoutStage
    let failureCode: String
}

func layoutCloseoutFailureCode(_ error: Error) -> String {
    if let error = error as? LayoutCloseoutError { return "closeout-\(error.rawValue)" }
    if let error = error as? RecoveryStoreError {
        switch error {
        case .ownershipUnavailable: return "store-ownership-unavailable"
        case .ioFailure: return "store-io"
        case .invalidDirectory, .insecureDirectory, .unsafeRecordFile: return "store-unsafe-storage"
        default: return "recovery-store"
        }
    }
    if error is DecodingError { return "request-decoding" }
    return snapshotWitnessFailureCode(error)
}

struct LayoutCloseoutEntry: Codable {
    let role: String
    let directory: String
    let device: Int64
    let inode: UInt64
    let originalSHA256: String
    let session: UUID
    let generation: UInt64
}

struct LayoutCloseoutRequest: Codable {
    let scope: String
    let candidate: UUID
    let approved: Bool
    let adoptCurrentC: Bool
    let physicalObservationConfirmed: Bool
    let observedAtNanoseconds: UInt64
    let probeSHA256: String
    let internalHardwareIdentity: InternalDisplayHardwareIdentity
    let expectedC: Snapshot
    let records: [LayoutCloseoutEntry]
    let evidenceDirectory: String

    func validate(now: UInt64, probeSHA256 actual: String) throws {
        guard scope == "legacy-layout-record-closeout-v1", approved, adoptCurrentC, physicalObservationConfirmed,
              observedAtNanoseconds <= now, now - observedAtNanoseconds <= 600_000_000_000,
              probeSHA256 == actual, records.count == 2, records.map(\.role) == ["old-1", "old-2"],
              Set(records.map(\.directory)).count == 2,
              records.allSatisfy({ $0.inode > 0 && $0.generation > 0 && $0.originalSHA256.count == 64 }),
              expectedC.displays.count == 2,
              Set(expectedC.displays.map(\.identity)) == [.builtIn, .physical],
              Set(expectedC.displays.map(\.id)).count == 2,
              expectedC.displays.allSatisfy({ $0.id != 0 && $0.isOnline && $0.isActive && !$0.isMirrored }),
              expectedC.displays.filter(\.isMain).count == 1,
              expectedC.displays.first(where: \.isMain)?.identity == .builtIn else {
            throw LayoutCloseoutError.authorization
        }
        try internalHardwareIdentity.validate()
        _ = try expectedC.layout()
    }
}

// Purpose-specific private evidence; never creates parent directories, follows leaf links or overwrites files.
final class LayoutCloseoutDirectory {
    let url: URL
    let descriptor: Int32
    private let identity: stat

    init(_ path: String) throws {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw LayoutCloseoutError.storage
        }
        url = URL(fileURLWithPath: path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LayoutCloseoutError.storage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            close(fd)
            throw LayoutCloseoutError.storage
        }
        descriptor = fd
        identity = info
    }

    deinit { close(descriptor) }

    func verify(device: Int64? = nil, inode: UInt64? = nil) throws {
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              current.st_uid == getuid(), current.st_mode & 0o7777 == 0o700,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              device == nil || device == Int64(current.st_dev), inode == nil || inode == current.st_ino else {
            throw LayoutCloseoutError.storage
        }
    }

    func read(_ name: String) throws -> Data {
        try verify()
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LayoutCloseoutError.storage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600,
              info.st_size >= 0, info.st_size <= 1_048_576 else { throw LayoutCloseoutError.storage }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw LayoutCloseoutError.storage }
        return data
    }

    func write(_ name: String, data: Data) throws {
        try verify()
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LayoutCloseoutError.storage }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw LayoutCloseoutError.storage }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        for target in [fd, descriptor] {
            while fsync(target) != 0 {
                guard errno == EINTR else { throw LayoutCloseoutError.storage }
            }
        }
        try verify()
    }

    func write<T: Encodable>(_ name: String, value: T) throws {
        try write(name, data: JSONEncoder().encode(value))
    }
}

func layoutCloseoutSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Limited known-image sampling; renamed controllers and short-lived processes remain an explicit blind spot.
func checkLayoutCloseoutProcesses() throws {
    let currentPID = getpid()
    try checkLayoutCloseoutProcesses(currentPID: currentPID,
        list: { buffer, capacity in proc_listpids(UInt32(PROC_UID_ONLY), getuid(), buffer, capacity) },
        image: { pid in
            var path = [CChar](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { return nil }
            return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        },
        isGone: { pid in kill(pid, 0) == -1 && errno == ESRCH },
        isOwnWitness: { pid, image in
            var info = proc_bsdinfo()
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
                && info.pbi_ppid == UInt32(currentPID)
                && URL(fileURLWithPath: image).resolvingSymlinksInPath() == Bundle.main.executableURL?.resolvingSymlinksInPath()
        })
}

func checkLayoutCloseoutProcesses(
    currentPID: pid_t,
    list: (UnsafeMutableRawPointer?, Int32) -> Int32,
    image: (pid_t) -> String?,
    isGone: (pid_t) -> Bool,
    isOwnWitness: (pid_t, String) -> Bool
) throws {
    let bytes = list(nil, 0)
    guard bytes > 0 else { throw LayoutCloseoutError.processListSizing }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 1024)
    let count = pids.withUnsafeMutableBytes { list($0.baseAddress, Int32($0.count)) }
    guard count > 0, Int(count) < pids.count * MemoryLayout<pid_t>.size else { throw LayoutCloseoutError.processListRead }
    for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) where pid > 0 && pid != currentPID {
        guard let path = image(pid) else {
            if isGone(pid) { continue }
            throw LayoutCloseoutError.processImageUnavailable
        }
        guard ["Extilume", "extilume-probe", "native-primary-preparation"].contains(URL(fileURLWithPath: path).lastPathComponent) else { continue }
        guard isOwnWitness(pid, path) else { throw LayoutCloseoutError.controllerPresent }
    }
}

func performLayoutRecordCloseout(
    request: LayoutCloseoutRequest, requestBytes: Data, executableSHA256: String,
    now: @escaping () throws -> UInt64 = { try ContinuousClock.nanoseconds() },
    boot: @escaping () throws -> UUID = currentBootSession,
    quiet: @escaping () throws -> Void = checkLayoutCloseoutProcesses,
    snapshot: @escaping (_ deadline: UInt64, _ check: () throws -> Void) throws -> Snapshot = { deadline, check in
        try withoutActuallyEscaping(check) { access in
            try freshWitness(Snapshot.self, arguments: ["--display-snapshot"],
                             deadlineNanoseconds: deadline, checkAccess: access, validate: { _ in true })
        }
    },
    internalState: @escaping (_ identity: UUID, _ id: UInt32, _ hardware: InternalDisplayHardwareIdentity,
                    _ deadline: UInt64, _ check: () throws -> Void) throws -> InternalDisplayState = { identity, id, hardware, deadline, check in
        try withoutActuallyEscaping(check) { access in
            try freshInternalDisplay(identity: identity, numericIDHint: id, hardwareIdentity: hardware,
                                     trace: { _ in }, deadlineNanoseconds: deadline, checkAccess: access)
        }
    }
) throws {
    let start = try now()
    try request.validate(now: start, probeSHA256: executableSHA256)
    guard start <= UInt64.max - 30_000_000_000 else { throw LayoutCloseoutError.environment }
    let deadline = start + 30_000_000_000
    let evidence = try LayoutCloseoutDirectory(request.evidenceDirectory)
    try evidence.write("attempt.json", value: ["candidate": request.candidate.uuidString,
                                               "requestSHA256": layoutCloseoutSHA256(requestBytes)])
    var lastCheck = start
    var observation = 0
    var completed: [String] = []
    var stage = LayoutCloseoutStage.records
    func checkpoint(force: Bool = false) throws {
        let callerStage = stage
        stage = .clock
        let time = try now()
        guard time >= lastCheck, time < deadline, time - lastCheck <= 3_000_000_000 else { throw LayoutCloseoutError.environment }
        stage = .boot
        guard try boot() == request.internalHardwareIdentity.bootSession else { throw LayoutCloseoutError.environment }
        stage = .evidence
        try evidence.verify()
        let scanned = force || time - lastCheck >= 1_000_000_000
        if scanned {
            stage = .processes
            try quiet()
        }
        stage = .clock
        let after = try now()
        guard after >= time, after < deadline, after - lastCheck <= 3_000_000_000 else {
            throw LayoutCloseoutError.environment
        }
        if scanned { lastCheck = after }
        stage = callerStage
    }
    func verify() throws {
        try checkpoint(force: true)
        stage = .snapshotFirst
        let first = try snapshot(deadline, { try checkpoint() })
        stage = .snapshotSecond
        let second = try snapshot(deadline, { try checkpoint() })
        stage = .layout
        guard first == request.expectedC, second == first,
              let inner = second.displays.first(where: { $0.identity == .builtIn }), let identity = inner.identityUUID else {
            throw LayoutCloseoutError.observation
        }
        stage = .internalWitness
        let state = try internalState(identity, inner.id, request.internalHardwareIdentity, deadline, { try checkpoint() })
        stage = .internalState
        guard state.id == inner.id, state.identityUUID == identity, state.reportedIdentityUUID == identity,
              state.isBuiltIn, state.isEnabled, state.hardwareIdentity == request.internalHardwareIdentity else {
            throw LayoutCloseoutError.observation
        }
        try checkpoint(force: true)
        observation += 1
        stage = .observationReceipt
        try evidence.write("observation-\(observation).json", value: second)
        try evidence.write("internal-\(observation).json", value: state)
        try checkpoint(force: true)
    }
    do {
        // Hold both owners before the first record can change.
        let directories = try request.records.map { try LayoutCloseoutDirectory($0.directory) }
        let stores = try directories.map { try RecoveryStore(directory: $0.url) }
        for (index, entry) in request.records.enumerated() {
            stage = .ownership
            try directories[index].verify(device: entry.device, inode: entry.inode)
            try stores[index].verifyDirectoryIdentity(device: entry.device, inode: entry.inode)
            try stores[index].acquireExclusiveOwnership()
        }
        func verifySources() throws {
            let callerStage = stage
            stage = .sourceIdentity
            for (index, entry) in request.records.enumerated() {
                try directories[index].verify(device: entry.device, inode: entry.inode)
                try stores[index].verifyDirectoryIdentity(device: entry.device, inode: entry.inode)
            }
            stage = callerStage
        }
        try verify()
        stage = .recordBinding
        var originals: [Data] = []
        var candidates: [RecoveryRecord] = []
        for (index, entry) in request.records.enumerated() {
            guard let original = try stores[index].loadWithOriginalBytes(),
                  layoutCloseoutSHA256(original.bytes) == entry.originalSHA256,
                  original.record.session == entry.session, original.record.generation == entry.generation else {
                throw LayoutCloseoutError.storage
            }
            candidates.append(try original.record.confirmingLayoutCloseout(actual: request.expectedC.layout()))
            originals.append(original.bytes)
        }
        stage = .backup
        for (index, entry) in request.records.enumerated() {
            try evidence.write("\(entry.role)-original.json", data: originals[index])
        }
        var closedHashes: [String] = []
        for (index, entry) in request.records.enumerated() {
            stage = .save
            let closed = try stores[index].closeLayoutResponsibility(
                expectedOriginal: originals[index], target: request.expectedC.layout(),
                backup: { data in
                    stage = .backup
                    guard try evidence.read("\(entry.role)-original.json") == data else { throw LayoutCloseoutError.storage }
                    stage = .save
                },
                verify: {
                    try verifySources()
                    try verify()
                    stage = .save
                },
                beforeSave: {
                    stage = .saveIntent
                    try evidence.write("\(entry.role)-save-requested.json", value: ["originalSHA256": entry.originalSHA256])
                    try verify()
                    stage = .save
                }, checkBeforeCommit: {
                    try checkpoint(force: true)
                    try verifySources()
                    try checkpoint()
                })
            stage = .savedRecord
            guard let saved = try stores[index].loadWithOriginalBytes(), saved.record == closed else {
                throw LayoutCloseoutError.storage
            }
            let afterSHA256 = layoutCloseoutSHA256(saved.bytes)
            try evidence.write("\(entry.role)-restored.json", data: saved.bytes)
            try evidence.write("\(entry.role)-verified.json", value: ["beforeSHA256": entry.originalSHA256,
                "afterSHA256": afterSHA256, "session": closed.session.uuidString, "generation": String(closed.generation)])
            closedHashes.append(afterSHA256)
            completed.append(entry.role)
        }
        try verify()
        stage = .finalVerification
        for index in stores.indices {
            guard let saved = try stores[index].loadWithOriginalBytes(), saved.record == candidates[index],
                  layoutCloseoutSHA256(saved.bytes) == closedHashes[index] else { throw LayoutCloseoutError.storage }
        }
        try verifySources()
        try checkpoint(force: true)
        stage = .completion
        try evidence.write("complete.json", value: ["verifiedRoles": completed])
        try checkpoint(force: true)
    } catch {
        try? evidence.write("stopped.json", value: LayoutCloseoutStoppedReceipt(
            verifiedRoles: completed, stage: stage, failureCode: layoutCloseoutFailureCode(error)))
        throw error
    }
}

func runLayoutRecordCloseout(requestPath: String) throws {
    let url = URL(fileURLWithPath: requestPath)
    guard requestPath.hasPrefix("/"), let executable = Bundle.main.executableURL else { throw LayoutCloseoutError.authorization }
    let input = try LayoutCloseoutDirectory(url.deletingLastPathComponent().path)
    let bytes = try input.read(url.lastPathComponent)
    let request = try JSONDecoder().decode(LayoutCloseoutRequest.self, from: bytes)
    try performLayoutRecordCloseout(request: request, requestBytes: bytes,
                                   executableSHA256: layoutCloseoutSHA256(Data(contentsOf: executable)))
}
