import Foundation

enum InboxItemStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case opened
    case completed
    case dismissed

    var displayLabel: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .opened: String(localized: "Opened")
        case .completed: String(localized: "Completed")
        case .dismissed: String(localized: "Dismissed")
        }
    }
}
