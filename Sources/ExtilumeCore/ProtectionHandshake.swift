import Foundation

public struct ProtectionHandshake: Codable, Equatable {
    public let version: Int
    public let session: UUID
    public let generation: UInt64
    public let parentPID: Int32
    public let internalDisplayIdentity: UUID?
    public let internalDisplayHardwareIdentity: InternalDisplayHardwareIdentity?

    public init(
        session: UUID,
        generation: UInt64,
        parentPID: Int32,
        internalDisplayIdentity: UUID? = nil,
        internalDisplayHardwareIdentity: InternalDisplayHardwareIdentity? = nil
    ) throws {
        version = internalDisplayHardwareIdentity == nil ? 1 : 2
        self.session = session
        self.generation = generation
        self.parentPID = parentPID
        self.internalDisplayIdentity = internalDisplayIdentity
        self.internalDisplayHardwareIdentity = internalDisplayHardwareIdentity
        try validate()
    }

    public func validate() throws {
        let hardwareIdentityValid: Bool
        switch version {
        case 1:
            hardwareIdentityValid = internalDisplayHardwareIdentity == nil
        case 2:
            if let hardwareIdentity = internalDisplayHardwareIdentity,
               internalDisplayIdentity != nil {
                do {
                    try hardwareIdentity.validate()
                    hardwareIdentityValid = true
                } catch {
                    hardwareIdentityValid = false
                }
            } else {
                hardwareIdentityValid = false
            }
        default:
            hardwareIdentityValid = false
        }
        guard hardwareIdentityValid, generation >= 1, parentPID > 1 else { throw RecoveryError.invalidRecord }
    }

    public func accepts(record: RecoveryRecord) -> Bool {
        session == record.session && record.generation >= generation &&
            internalDisplayIdentity == record.internalDisplay?.identity &&
            internalDisplayHardwareIdentity == record.internalDisplay?.hardwareIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case version, session, generation, parentPID, internalDisplayIdentity, internalDisplayHardwareIdentity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        session = try values.decode(UUID.self, forKey: .session)
        generation = try values.decode(UInt64.self, forKey: .generation)
        parentPID = try values.decode(Int32.self, forKey: .parentPID)
        internalDisplayIdentity = try values.decodeIfPresent(UUID.self, forKey: .internalDisplayIdentity)
        internalDisplayHardwareIdentity = try values.decodeIfPresent(
            InternalDisplayHardwareIdentity.self, forKey: .internalDisplayHardwareIdentity
        )
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

    public func verifyAcknowledgement(record: RecoveryRecord) throws {
        guard ready, !lost, let acknowledgedHandshake else { throw RecoveryError.unfinishedTransaction }
        guard acknowledgedHandshake.accepts(record: record) else { throw RecoveryError.identityConflict }
    }

    public func authorize(record: RecoveryRecord) throws {
        try verifyAcknowledgement(record: record)
        guard record.phase == .prepared || record.phase == .applying else { throw RecoveryError.invalidTransition }
        guard !record.sourceUnresolved else { throw RecoveryError.unresolvedSource }
    }
}
