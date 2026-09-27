import SwiftUI

enum SyncStatus: String, Codable, Hashable, Sendable {
    case synced
    case syncing
    case offline
    case error

    var displayLabel: String {
        switch self {
        case .synced: String(localized: "Synced")
        case .syncing: String(localized: "Syncing")
        case .offline: String(localized: "Offline")
        case .error: String(localized: "Sync Error")
        }
    }

    var displayIcon: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        case .error: "exclamationmark.icloud"
        }
    }

    var displayColor: Color {
        switch self {
        case .synced: .green
        case .syncing: .orange
        case .offline: .secondary
        case .error: .red
        }
    }
}
