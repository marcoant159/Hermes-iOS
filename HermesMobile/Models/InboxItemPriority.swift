import Foundation

enum InboxItemPriority: String, Codable, Hashable, Sendable, CaseIterable {
    case low
    case normal
    case high
    case urgent

    var displayLabel: String {
        switch self {
        case .low: String(localized: "Low")
        case .normal: String(localized: "Normal")
        case .high: String(localized: "High")
        case .urgent: String(localized: "Urgent")
        }
    }
}
