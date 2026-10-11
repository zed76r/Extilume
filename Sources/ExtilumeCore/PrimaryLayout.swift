import Foundation

public func layoutByMakingMain(_ layout: DisplayLayout, target: UUID) throws -> DisplayLayout {
    guard let targetOrigin = layout.origins[target] else { throw RecoveryError.identityConflict }
    guard layout.main != target else { return layout }

    var translatedOrigins: [UUID: DisplayOrigin] = [:]
    for (identity, origin) in layout.origins {
        let x = Int64(origin.x) - Int64(targetOrigin.x)
        let y = Int64(origin.y) - Int64(targetOrigin.y)
        guard let translatedX = Int32(exactly: x),
              let translatedY = Int32(exactly: y) else {
            throw RecoveryError.invalidRecord
        }
        translatedOrigins[identity] = DisplayOrigin(x: translatedX, y: translatedY)
    }

    return try DisplayLayout(main: target, origins: translatedOrigins)
}
