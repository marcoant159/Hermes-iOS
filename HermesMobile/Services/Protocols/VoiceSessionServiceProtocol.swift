import Foundation

@MainActor
final class TalkSessionEventHub {
    private var continuations: [UUID: AsyncStream<TalkSessionEvent>.Continuation] = [:]

    func stream(initial snapshot: TalkSessionSnapshot) -> AsyncStream<TalkSessionEvent> {
        AsyncStream { continuation in
            let identifier = UUID()
            continuations[identifier] = continuation
            continuation.yield(.snapshot(snapshot))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    func publish(snapshot: TalkSessionSnapshot) {
        for continuation in continuations.values {
            continuation.yield(.snapshot(snapshot))
        }
    }
}

@MainActor
protocol VoiceSessionServiceProtocol {
    var snapshot: TalkSessionSnapshot { get }
    var voiceState: VoiceState { get }
    var connectionState: TalkConnectionState { get }
    var transcriptItems: [TranscriptItem] { get }
    var sessionDuration: TimeInterval { get }
    var isMuted: Bool { get }
    var blockedReason: String? { get }
    var statusMessage: String? { get }
    var canStartSession: Bool { get }
    var latencyMetrics: TalkLatencyMetrics { get }
    func events() -> AsyncStream<TalkSessionEvent>
    func refreshReadiness() async
    func startSession() async
    /// Starts a session while overriding the configured provider (wake word
    /// forces `codex_live`). `nil` keeps the configured provider.
    func startSession(providerOverride: String?) async
    func endSession() async
    func toggleMute() async
    func manuallyInterruptAssistantOutput()
    @discardableResult func sendImage(_ imageData: Data, mimeType: String, triggerResponse: Bool) -> Bool
    /// Injects a spoken command that never reached the realtime session (the
    /// wake word listener captured it). Waits for the session to be ready.
    func injectSpokenCommand(_ command: String) async
}
