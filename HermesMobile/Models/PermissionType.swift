import SwiftUI

enum PermissionType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case location
    case health
    case notifications
    case microphone
    case camera
    case photos
    case motion
    case speechRecognition

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .location: String(localized: "Location")
        case .health: String(localized: "Health")
        case .notifications: String(localized: "Notifications")
        case .microphone: String(localized: "Microphone")
        case .camera: String(localized: "Camera")
        case .photos: String(localized: "Photos")
        case .motion: String(localized: "Motion & Activity")
        case .speechRecognition: String(localized: "Speech Recognition")
        }
    }

    var displayIcon: String {
        switch self {
        case .location: "location.fill"
        case .health: "heart.fill"
        case .notifications: "bell.fill"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        case .photos: "photo.fill"
        case .motion: "figure.walk"
        case .speechRecognition: "waveform"
        }
    }

    var displayColor: Color {
        switch self {
        case .location: .blue
        case .health: .red
        case .notifications: .orange
        case .microphone: .indigo
        case .camera: .purple
        case .photos: .green
        case .motion: .teal
        case .speechRecognition: .cyan
        }
    }

    var explanation: String {
        switch self {
        case .location:
            String(localized: "Hermes uses your location to provide contextual recommendations, weather updates, and nearby suggestions.")
        case .health:
            String(localized: "Access your health data to offer personalized wellness insights, activity tracking, and sleep recommendations.")
        case .notifications:
            String(localized: "Receive timely reminders, task updates, and important alerts from Hermes.")
        case .microphone:
            String(localized: "Voice conversations with Hermes in Talk Mode.")
        case .camera:
            String(localized: "Capture photos and documents for Hermes to analyze, annotate, or organize.")
        case .photos:
            String(localized: "Access your photo library to help organize, search, and create albums based on your preferences.")
        case .motion:
            String(localized: "Hermes uses motion data to understand your current activity for contextual awareness.")
        case .speechRecognition:
            String(localized: "On-device speech recognition for dictation in the chat composer.")
        }
    }

    /// Permissions shown during onboarding. Camera, Photos, and Speech Recognition are deferred to Settings.
    static let onboardingPermissions: [PermissionType] = [.location, .notifications, .health, .microphone, .motion]
}
