import SwiftUI

enum PermissionStatus: String, Codable, Hashable, Sendable {
    case notDetermined
    case authorized
    case authorizedWhenInUse
    case authorizedAlways
    case limited
    case denied
    case restricted
    case unsupported

    var displayLabel: String {
        switch self {
        case .notDetermined: String(localized: "Not Set")
        case .authorized: String(localized: "Enabled")
        case .authorizedWhenInUse: String(localized: "While Using")
        case .authorizedAlways: String(localized: "Always")
        case .limited: String(localized: "Limited")
        case .denied: String(localized: "Denied")
        case .restricted: String(localized: "Restricted")
        case .unsupported: String(localized: "Unavailable")
        }
    }

    var displayColor: Color {
        switch self {
        case .notDetermined: .secondary
        case .authorized, .authorizedWhenInUse, .authorizedAlways: .green
        case .limited: .orange
        case .denied: .red
        case .restricted: .orange
        case .unsupported: .secondary
        }
    }

    var actionLabel: String? {
        switch self {
        case .notDetermined: String(localized: "Enable")
        case .authorized, .authorizedWhenInUse, .authorizedAlways: nil
        case .limited: String(localized: "Manage")
        case .denied: String(localized: "Open Settings")
        case .restricted: nil
        case .unsupported: nil
        }
    }
}

enum LocationAuthorizationLevel: String, Codable, Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    var displayLabel: String {
        switch self {
        case .notDetermined: String(localized: "Not Set")
        case .denied: String(localized: "Denied")
        case .restricted: String(localized: "Restricted")
        case .whenInUse: String(localized: "While Using")
        case .always: String(localized: "Always")
        }
    }
}

enum LocationAccuracyLevel: String, Codable, Hashable, Sendable {
    case unknown
    case full
    case reduced

    var displayLabel: String {
        switch self {
        case .unknown: String(localized: "Unknown Accuracy")
        case .full: String(localized: "Full Accuracy")
        case .reduced: String(localized: "Reduced Accuracy")
        }
    }
}
