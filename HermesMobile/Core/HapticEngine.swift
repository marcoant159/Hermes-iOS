import UIKit

/// Centralized haptic feedback utility.
///
/// All haptic methods are MainActor-isolated since `UIFeedbackGenerator`
/// must be used from the main thread.
@MainActor
enum HapticEngine {
    /// Light impact when a message is sent.
    static func messageSent() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium impact when a streaming response completes.
    static func responseReceived() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Light impact when a voice session starts.
    static func voiceSessionStarted() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Error notification for failed operations.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
