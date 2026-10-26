import Darwin
import Foundation

public enum RecoveryStoreError: Error, Equatable {
    case invalidDirectory
    case insecureDirectory
    case invalidRecord
    case corruptRecord
    case unsafeRecordFile
    case differentSessionPending
    case staleGeneration
    case unresolvedResponsibility
    case ioFailure
    case ownershipUnavailable
}

public final class RecoveryStore {
    private static let recordName = "recovery-record.json"
    private static let maximumRecordSize = 1_048_576

    private let directoryDescriptor: Int32
    private var ownsExclusiveLock = false

    public init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.isEmpty else {
            throw RecoveryStoreError.invalidDirectory
        }

        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw RecoveryStoreError.insecureDirectory
            }
            throw RecoveryStoreError.invalidDirectory
        }
        do {
            try Self.validateDirectory(descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        directoryDescriptor = descriptor
    }

    deinit {
        close(directoryDescriptor)
    }

    public func acquireExclusiveOwnership() throws {
        guard flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RecoveryStoreError.ownershipUnavailable
        }
        ownsExclusiveLock = true
    }

    public func apply(
        _ prepared: RecoveryRecord,
        beforeOperation: () throws -> Void = {},
        operation: () throws -> (layout: DisplayLayout, internalEnabled: Bool?)
    ) throws -> RecoveryRecord {
        guard prepared.externalDisplay == nil else { throw RecoveryError.invalidRecord }
        return try applyPrepared(prepared, beforeOperation: beforeOperation) {
            let result = try operation()
            return (result.layout, result.internalEnabled, nil)
        }
    }

    public func applyExternal(
        _ prepared: RecoveryRecord,
        beforeOperation: () throws -> Void = {},
        operation: () throws -> (layout: DisplayLayout, internalEnabled: Bool?, externalEnabled: Bool?)
    ) throws -> RecoveryRecord {
        guard prepared.externalDisplay != nil else { throw RecoveryError.invalidRecord }
        return try applyPrepared(prepared, beforeOperation: beforeOperation, operation: operation)
    }

    private func applyPrepared(
        _ prepared: RecoveryRecord,
        beforeOperation: () throws -> Void,
        operation: () throws -> (layout: DisplayLayout, internalEnabled: Bool?, externalEnabled: Bool?)
    ) throws -> RecoveryRecord {
        guard ownsExclusiveLock else { throw RecoveryStoreError.ownershipUnavailable }
        guard prepared.phase == .prepared, !prepared.sourceUnresolved else {
            throw RecoveryError.unfinishedTransaction
        }
        let previous = try load()
        if let existing = previous, !existing.canClear {
            guard existing.phase == .owned,
                  existing.session == prepared.session,
                  prepared.generation > existing.generation,
                  existing.baseline == prepared.baseline else { throw RecoveryError.unfinishedTransaction }
        }
        var record = prepared
        try save(record)
        try record.markApplying()
        try save(record)
        // 预检须无显示副作用；操作尚未调用时才可恢复到可重试的 owned。
        do { try beforeOperation() }
        catch {
            try record.cancelBeforeApplication(previous: previous)
            try save(record)
            throw error
        }
        // 控制回调只能在责任记录已原子落盘后运行；失败保留 applying 责任。
        let applyingRecord = record
        let actual = try operation()
        do {
            try record.confirmApplied(
                actual.layout,
                internalEnabled: actual.internalEnabled,
                externalEnabled: actual.externalEnabled
            )
        }
        catch {
            let confirmationError = error
            if record.sourceUnresolved, (try? load()) == applyingRecord {
                try save(record)
            }
            throw confirmationError
        }
        try save(record)
        return record
    }

    public func save(_ record: RecoveryRecord) throws {
        guard ownsExclusiveLock else { throw RecoveryStoreError.ownershipUnavailable }
        do {
            try record.validate()
        } catch {
            throw RecoveryStoreError.invalidRecord
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw RecoveryStoreError.invalidRecord
        }

        try Self.validateDirectory(directoryDescriptor)
        let existing = try load()
        if let existing, existing.session != record.session,
           existing.requiresRecovery || !existing.canClear {
            throw RecoveryStoreError.differentSessionPending
        }
        if let existing, existing.session == record.session, record.generation < existing.generation {
            throw RecoveryStoreError.staleGeneration
        }

        var backupToCleanup: String?
        defer {
            if let backupToCleanup {
                _ = unlinkat(directoryDescriptor, backupToCleanup, 0)
            }
        }

        let temporaryName = ".recovery-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw RecoveryStoreError.ioFailure }
        var ownsTemporary = true
        defer {
            if ownsTemporary { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { close(descriptor) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw RecoveryStoreError.ioFailure
        }

        try Self.writeAll(data, to: descriptor)
        try Self.synchronize(descriptor)
        let closeResult = close(descriptor)
        ownsDescriptor = false
        guard closeResult == 0 else { throw RecoveryStoreError.ioFailure }

        let backupName: String?
        if existing != nil {
            let name = ".recovery-backup-\(UUID().uuidString).tmp"
            guard linkat(directoryDescriptor, Self.recordName, directoryDescriptor, name, 0) == 0 else {
                throw RecoveryStoreError.ioFailure
            }
            backupName = name
            backupToCleanup = name
            try Self.synchronize(directoryDescriptor)
        } else {
            backupName = nil
        }

        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, Self.recordName) == 0 else {
            throw RecoveryStoreError.ioFailure
        }
        ownsTemporary = false
        do {
            try Self.synchronize(directoryDescriptor)
        } catch {
            if let backupName {
                if renameat(directoryDescriptor, backupName, directoryDescriptor, Self.recordName) == 0 {
                    backupToCleanup = nil
                    try? Self.synchronize(directoryDescriptor)
                } else {
                    // 回滚失败时保留旧记录硬链接，避免丢弃未恢复责任。
                    backupToCleanup = nil
                }
            } else if unlinkat(directoryDescriptor, Self.recordName, 0) == 0 {
                try? Self.synchronize(directoryDescriptor)
            }
            throw RecoveryStoreError.ioFailure
        }

        if let backupName, unlinkat(directoryDescriptor, backupName, 0) == 0 {
            backupToCleanup = nil
            try? Self.synchronize(directoryDescriptor)
        }
    }

    public func load() throws -> RecoveryRecord? {
        try Self.validateDirectory(directoryDescriptor)
        let descriptor = openat(
            directoryDescriptor,
            Self.recordName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw RecoveryStoreError.unsafeRecordFile }
            throw RecoveryStoreError.ioFailure
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RecoveryStoreError.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw RecoveryStoreError.unsafeRecordFile
        }
        guard info.st_size >= 0, info.st_size <= off_t(Self.maximumRecordSize) else {
            throw RecoveryStoreError.corruptRecord
        }

        let data: Data
        do {
            data = try Self.readAll(from: descriptor)
        } catch let error as RecoveryStoreError {
            throw error
        } catch {
            throw RecoveryStoreError.ioFailure
        }

        do {
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: data)
            try record.validate()
            return record
        } catch {
            throw RecoveryStoreError.corruptRecord
        }
    }

    public func clear() throws {
        guard ownsExclusiveLock else { throw RecoveryStoreError.ownershipUnavailable }
        guard let record = try load() else { return }
        guard record.canClear else { throw RecoveryStoreError.unresolvedResponsibility }

        if unlinkat(directoryDescriptor, Self.recordName, 0) != 0 {
            if errno == ENOENT { return }
            throw RecoveryStoreError.ioFailure
        }
        try Self.synchronize(directoryDescriptor)
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RecoveryStoreError.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw RecoveryStoreError.insecureDirectory
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                if data.isEmpty { return }
                throw RecoveryStoreError.ioFailure
            }
            var offset = 0
            while offset < bytes.count {
                let written = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw RecoveryStoreError.ioFailure
                }
            }
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard data.count <= maximumRecordSize - count else {
                    throw RecoveryStoreError.corruptRecord
                }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw RecoveryStoreError.ioFailure
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw RecoveryStoreError.ioFailure }
        }
    }
}
