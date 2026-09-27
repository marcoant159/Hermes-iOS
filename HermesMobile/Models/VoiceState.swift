import SwiftUI

enum VoiceState: String, Codable, Hashable, Sendable, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking
    case interrupted
    case disconnected

    var displayLabel: String {
        switch self {
        case .idle: String(localized: "Ready")
        case .listening: String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .speaking: String(localized: "Speaking")
        case .interrupted: String(localized: "Interrupted")
        case .disconnected: String(localized: "Disconnected")
        }
    }

    var displayIcon: String {
        switch self {
        case .idle: "mic.slash"
        case .listening: "mic.fill"
        case .thinking: "brain"
        case .speaking: "speaker.wave.2.fill"
        case .interrupted: "pause.circle.fill"
        case .disconnected: "wifi.slash"
        }
    }

    var displayColor: Color {
        switch self {
        case .idle: .secondary
        case .listening: .blue
        case .thinking: .purple
        case .speaking: .green
        case .interrupted: .orange
        case .disconnected: Color.white.opacity(0.15)
        }
    }
}

enum TalkConnectionState: String, Codable, Hashable, Sendable {
    case idle
    case checking
    case ready
    case connecting
    case connected
    case blocked
    case failed

    var displayLabel: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .checking: String(localized: "Checking")
        case .ready: String(localized: "Ready")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .blocked: String(localized: "Unavailable")
        case .failed: String(localized: "Failed")
        }
    }
}

enum TranscriptSpeaker: String, Codable, Hashable, Sendable {
    case user
    case hermes
    case system

    var displayLabel: String {
        switch self {
        case .user: String(localized: "You")
        case .hermes: "Hermes"
        case .system: String(localized: "System")
        }
    }
}

struct TranscriptItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var speaker: TranscriptSpeaker
    var text: String
    var isPartial: Bool
    var imageData: Data?  // JPEG thumbnail for display in transcript

    init(
        id: UUID = UUID(),
        speaker: TranscriptSpeaker,
        text: String,
        isPartial: Bool = false,
        imageData: Data? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.isPartial = isPartial
        self.imageData = imageData
    }
}

struct TalkLatencyMetrics: Codable, Hashable, Sendable {
    var sessionStartRequestedAt: Date? = nil
    var relayBootstrapReceivedAt: Date? = nil
    var realtimeConnectedAt: Date? = nil
    var firstUserFinalizedAt: Date? = nil
    var firstAssistantFinalizedAt: Date? = nil

    var bootstrapLatency: TimeInterval? {
        guard let sessionStartRequestedAt, let relayBootstrapReceivedAt else { return nil }
        return relayBootstrapReceivedAt.timeIntervalSince(sessionStartRequestedAt)
    }

    var connectLatency: TimeInterval? {
        guard let sessionStartRequestedAt, let realtimeConnectedAt else { return nil }
        return realtimeConnectedAt.timeIntervalSince(sessionStartRequestedAt)
    }

    var firstAssistantLatency: TimeInterval? {
        guard let sessionStartRequestedAt, let firstAssistantFinalizedAt else { return nil }
        return firstAssistantFinalizedAt.timeIntervalSince(sessionStartRequestedAt)
    }
}

struct TalkSessionSnapshot: Hashable, Sendable {
    var voiceState: VoiceState
    var connectionState: TalkConnectionState
    var transcriptItems: [TranscriptItem]
    var sessionDuration: TimeInterval
    var isMuted: Bool
    var blockedReason: String?
    var statusMessage: String?
    var canStartSession: Bool
    var latencyMetrics: TalkLatencyMetrics
    var voiceSessionID: UUID?
    /// `true` while an async Hermes delegation is still being polled. Used to
    /// show "Consultando o Hermes" and to hold off the idle auto-close.
    var isDelegationInProgress: Bool = false
}

enum TalkSessionEvent: Hashable, Sendable {
    case snapshot(TalkSessionSnapshot)
}
