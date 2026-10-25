import Foundation

public enum DisplayApplicationMode: String, Codable, Sendable, CaseIterable {
    case externalPrimary
    case externalOnly

    public var title: String {
        switch self {
        case .externalPrimary: "外屏主屏"
        case .externalOnly: "仅外屏（停用内屏）"
        }
    }
}
