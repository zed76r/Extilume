import Foundation

public struct ProtectionHandshake: Codable, Equatable {
    public let version: Int
    public let session: UUID
    public let generation: UInt64
    public let parentPID: Int32

    public init(session: UUID, generation: UInt64, parentPID: Int32) throws {
        version = 1
        self.session = session
        self.generation = generation
        self.parentPID = parentPID
        try validate()
    }

    public func validate() throws {
        guard version == 1, generation >= 1, parentPID > 1 else { throw RecoveryError.invalidRecord }
    }

    public func accepts(record: RecoveryRecord) -> Bool {
        session == record.session && record.generation >= generation
    }

    private enum CodingKeys: String, CodingKey {
        case version, session, generation, parentPID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        session = try values.decode(UUID.self, forKey: .session)
        generation = try values.decode(UInt64.self, forKey: .generation)
        parentPID = try values.decode(Int32.self, forKey: .parentPID)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "保护握手字段无效"
            ))
        }
    }
}

public struct ProtectionAuthorization {
    public private(set) var ready = false
    public private(set) var lost = false
    private var acknowledgedHandshake: ProtectionHandshake?

    public init() {}

    public mutating func acknowledge(receipt: ProtectionHandshake, expected: ProtectionHandshake) throws {
        ready = false
        acknowledgedHandshake = nil
        guard !lost else { throw RecoveryError.unfinishedTransaction }
        try receipt.validate()
        try expected.validate()
        guard receipt == expected else { throw RecoveryError.identityConflict }
        acknowledgedHandshake = expected
        ready = true
    }

    public mutating func markLost() {
        lost = true
        ready = false
        acknowledgedHandshake = nil
    }

    public func authorize(record: RecoveryRecord) throws {
        guard ready, !lost, let acknowledgedHandshake else { throw RecoveryError.unfinishedTransaction }
        guard acknowledgedHandshake.accepts(record: record) else { throw RecoveryError.identityConflict }
        guard record.phase == .prepared || record.phase == .applying else { throw RecoveryError.invalidTransition }
        guard !record.sourceUnresolved else { throw RecoveryError.unresolvedSource }
    }
}
