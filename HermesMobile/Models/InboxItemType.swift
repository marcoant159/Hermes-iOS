import SwiftUI

enum InboxItemType: String, Codable, Hashable, Sendable, CaseIterable {
    case approval
    case notification
    case reminder
    case suggestion
    case alert

    var displayLabel: String {
        switch self {
        case .approval: String(localized: "Approval")
        case .notification: String(localized: "Notification")
        case .reminder: String(localized: "Reminder")
        case .suggestion: String(localized: "Suggestion")
        case .alert: String(localized: "Alert")
        }
    }

    var displayIcon: String {
        switch self {
        case .approval: "checkmark.seal.fill"
        case .notification: "bell.badge.fill"
        case .reminder: "clock.fill"
        case .suggestion: "lightbulb.fill"
        case .alert: "exclamationmark.triangle.fill"
        }
    }

    var displayColor: Color {
        switch self {
        case .approval: .orange
        case .notification: .blue
        case .reminder: .purple
        case .suggestion: .teal
        case .alert: .red
        }
    }
}
