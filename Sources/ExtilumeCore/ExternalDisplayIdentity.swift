import Foundation

public struct ExternalDisplayIdentity: Codable, Equatable, Sendable {
    public let uuid: UUID
    public let registryPath: String
    public let edidUUID: String
    public let bootSession: UUID
    public let registryEntryID: UInt64

    public init(
        uuid: UUID,
        registryPath: String,
        edidUUID: String,
        bootSession: UUID,
        registryEntryID: UInt64
    ) {
        self.uuid = uuid
        self.registryPath = registryPath
        self.edidUUID = edidUUID
        self.bootSession = bootSession
        self.registryEntryID = registryEntryID
    }

    public func validate() throws {
        let emptyUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard uuid != emptyUUID,
              !registryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !edidUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bootSession != emptyUUID,
              registryEntryID > 0 else {
            throw RecoveryError.invalidRecord
        }
    }
}
