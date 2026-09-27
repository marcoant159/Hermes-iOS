import ActivityKit
import Foundation

/// Shared attributes for Hermes Live Activities.
/// Used by both the main app (to start/update activities) and the widget extension (to render them).
struct HermesActivityAttributes: ActivityAttributes, Sendable {
    /// Dynamic data — updated throughout the activity's lifetime.
    struct ContentState: Codable, Hashable, Sendable {
        var status: String            // pt-BR label shown as the main line
        var toolName: String?         // e.g., "hermes_delegate", "vision_analyze"
        var elapsedSeconds: Int       // seconds since activity started (fallback for non-timer contexts)
        var startDate: Date?          // used by Text(timerInterval:) for a live-ticking clock
        var sessionType: String       // "voice", "chat", "tool"

        // Optional fields added incrementally. Older activities already in
        // flight decode them as nil, so adding them stays backward compatible.

        /// One of "connecting", "listening", "thinking", "speaking",
        /// "delegating", "working", "completed". Drives icon/color choices.
        var phase: String? = nil
        /// Engine powering a voice session, e.g. "GPT Live".
        var engineName: String? = nil
        /// Short user question tied to the activity (voice delegation / chat).
        var prompt: String? = nil
        /// Short answer preview shown for a few seconds after completion.
        var answerPreview: String? = nil
        /// Progress in 0...1 while delegating or working.
        var progress: Double? = nil
        /// Microphone muted state for voice sessions (drives the mute button).
        var isMuted: Bool? = nil
    }

    /// Immutable for the lifetime of the activity.
    var agentName: String = "Hermes"
}
