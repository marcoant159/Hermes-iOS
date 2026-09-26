import Foundation

/// Metadata captured when a voice session completes, used to trigger transcript injection.
struct CompletedVoiceSession: Sendable {
    let voiceSessionId: UUID
    let duration: TimeInterval
    let turnCount: Int
}

@MainActor
@Observable
final class TalkStore {
    var voiceState: VoiceState = .idle
    var connectionState: TalkConnectionState = .idle
    var transcriptItems: [TranscriptItem] = []
    var sessionDuration: TimeInterval = 0
    var isMuted = false
    var isSessionActive = false
    var blockedReason: String?
    var statusMessage: String?
    var canStartSession = true
    var latencyMetrics = TalkLatencyMetrics()
    var voiceSessionID: UUID?

    /// Set after a voice session ends; consumed by MainTabView to trigger transcript injection.
    var lastCompletedSession: CompletedVoiceSession?

    /// `true` while the current session was opened by the "oi hermes" wake word.
    /// Only these sessions auto-close on silence and release the mic back to the
    /// wake listener when they end.
    private(set) var isWakeWordSession = false

    /// Called when voice session state changes (start/end/state transition).
    var onSessionStateChanged: (@MainActor () -> Void)?

    /// Auto-close wake-word sessions after this much silence (no user or
    /// assistant speech and no Hermes delegation in progress).
    private static let wakeWordIdleTimeout: TimeInterval = 30

    private let voiceService: any VoiceSessionServiceProtocol
    private let liveActivity = LiveActivityService()
    private var eventTask: Task<Void, Never>?
    private var wakeWordIdleTask: Task<Void, Never>?
    private var wakeWordSessionActivated = false
    private var lastWakeWordActivityAt = Date()
    private var lastActivityTranscripts: [TranscriptItem] = []
    private var lastActivityVoiceState: VoiceState = .idle

    init(voiceService: any VoiceSessionServiceProtocol) {
        self.voiceService = voiceService
        applySnapshot(voiceService.snapshot)
        subscribeToEvents()
    }

    func refreshReadiness() async {
        await voiceService.refreshReadiness()
        applySnapshot(voiceService.snapshot)
    }

    /// Re-sync Live Activity state when returning from background.
    func handleAppDidBecomeActive() {
        liveActivity.handleAppDidBecomeActive()
    }

    /// Start without a prior readiness check — goes straight to session create.
    func startSessionDirectly() async {
        canStartSession = true
        connectionState = .connecting
        voiceState = .thinking
        statusMessage = "Connecting..."
        await voiceService.startSession()
        applySnapshot(voiceService.snapshot)
        if isSessionActive {
            liveActivity.startVoiceSession()
        }
    }

    func startSession() async {
        await voiceService.startSession()
        applySnapshot(voiceService.snapshot)
        if isSessionActive {
            liveActivity.startVoiceSession()
        }
    }

    /// Opens a GPT Live session from the wake word, forcing `codex_live`. Runs
    /// without any UI so it also works in the background / locked screen.
    func startWakeWordSession(providerOverride: String) async {
        guard !isSessionActive else { return }
        isWakeWordSession = true
        wakeWordSessionActivated = false
        lastWakeWordActivityAt = .now
        lastActivityTranscripts = transcriptItems
        lastActivityVoiceState = voiceState
        startWakeWordIdleWatchdog()
        canStartSession = true
        connectionState = .connecting
        voiceState = .thinking
        statusMessage = "Connecting..."
        await voiceService.startSession(providerOverride: providerOverride)
        applySnapshot(voiceService.snapshot)

        // Readiness may be stale when the wake word fires from the background.
        if !isSessionActive, !canStartSession {
            await voiceService.refreshReadiness()
            applySnapshot(voiceService.snapshot)
            if canStartSession {
                await voiceService.startSession(providerOverride: providerOverride)
                applySnapshot(voiceService.snapshot)
            }
        }

        if isSessionActive {
            liveActivity.startVoiceSession()
        } else {
            isWakeWordSession = false
            wakeWordSessionActivated = false
            wakeWordIdleTask?.cancel()
            wakeWordIdleTask = nil
        }
    }

    /// Sends a wake-word command that never reached the realtime server.
    func injectSpokenCommand(_ command: String) async {
        await voiceService.injectSpokenCommand(command)
    }

    private func startWakeWordIdleWatchdog() {
        wakeWordIdleTask?.cancel()
        wakeWordIdleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.isWakeWordSession, self.isSessionActive else { continue }
                // Never time out while Hermes is still working on a delegation.
                guard !self.voiceService.snapshot.isDelegationInProgress else {
                    self.lastWakeWordActivityAt = .now
                    continue
                }
                if Date().timeIntervalSince(self.lastWakeWordActivityAt) >= Self.wakeWordIdleTimeout {
                    await self.endSession()
                }
            }
        }
    }

    func endSession() async {
        // Capture session metadata before the service resets
        let sessionId = voiceSessionID
        let duration = sessionDuration
        let turnCount = transcriptItems.filter { !$0.isPartial }.count

        isWakeWordSession = false
        wakeWordSessionActivated = false
        wakeWordIdleTask?.cancel()
        wakeWordIdleTask = nil

        // End Live Activity
        liveActivity.endActivity()

        await voiceService.endSession()
        applySnapshot(voiceService.snapshot)

        // Publish completed session for injection
        if let sessionId, turnCount > 0 {
            lastCompletedSession = CompletedVoiceSession(
                voiceSessionId: sessionId,
                duration: duration,
                turnCount: turnCount
            )
        }
    }

    func toggleMute() async {
        await voiceService.toggleMute()
        applySnapshot(voiceService.snapshot)
    }

    /// Manually interrupt assistant speech (e.g., from a stop button).
    /// Unlike VAD-triggered interruption, this sends cancel + clear + truncate.
    func interruptAssistant() {
        voiceService.manuallyInterruptAssistantOutput()
        applySnapshot(voiceService.snapshot)
    }

    /// Send an image to the Realtime model during an active voice session.
    @discardableResult
    func sendImage(_ imageData: Data, triggerResponse: Bool = true) -> Bool {
        guard isSessionActive else { return false }
        return voiceService.sendImage(imageData, mimeType: "image/jpeg", triggerResponse: triggerResponse)
    }

    func endSessionIfNeeded() async {
        guard isSessionActive else { return }
        await endSession()
    }

    func clearLastCompletedSession() {
        lastCompletedSession = nil
    }

    func reset() {
        voiceState = .idle
        connectionState = .idle
        transcriptItems = []
        sessionDuration = 0
        isMuted = false
        isSessionActive = false
        blockedReason = nil
        statusMessage = nil
        canStartSession = true
        latencyMetrics = TalkLatencyMetrics()
        voiceSessionID = nil
        lastCompletedSession = nil
        isWakeWordSession = false
        wakeWordSessionActivated = false
        wakeWordIdleTask?.cancel()
        wakeWordIdleTask = nil
    }

    private func subscribeToEvents() {
        eventTask?.cancel()
        let stream = voiceService.events()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
                    self.applySnapshot(snapshot)
                }
            }
        }
    }

    private func applySnapshot(_ snapshot: TalkSessionSnapshot) {
        voiceState = snapshot.voiceState
        connectionState = snapshot.connectionState
        transcriptItems = snapshot.transcriptItems
        sessionDuration = snapshot.sessionDuration
        isMuted = snapshot.isMuted
        blockedReason = snapshot.blockedReason
        statusMessage = snapshot.statusMessage
        canStartSession = snapshot.canStartSession
        latencyMetrics = snapshot.latencyMetrics
        voiceSessionID = snapshot.voiceSessionID
        isSessionActive = connectionState == .connecting || connectionState == .connected

        // A wake-word session that connected and then dropped must not keep the
        // wake-word Live Activity labels around. Only clear after we actually
        // saw it active, so the "connecting"/"checking" window is not mistaken
        // for a failure.
        if isSessionActive, isWakeWordSession {
            wakeWordSessionActivated = true
        }
        if !isSessionActive, isWakeWordSession, wakeWordSessionActivated {
            isWakeWordSession = false
            wakeWordSessionActivated = false
            wakeWordIdleTask?.cancel()
            wakeWordIdleTask = nil
        }

        // Any user or assistant turn counts as activity for the wake-word
        // idle watchdog (input/output transcripts and turn.* all mutate these).
        if snapshot.transcriptItems != lastActivityTranscripts
            || snapshot.voiceState != lastActivityVoiceState {
            lastWakeWordActivityAt = .now
            lastActivityTranscripts = snapshot.transcriptItems
            lastActivityVoiceState = snapshot.voiceState
        }

        // Update Live Activity on voice state changes
        if isSessionActive {
            let status: String
            switch snapshot.voiceState {
            case .listening:
                status = isWakeWordSession ? "Conversando" : "Listening"
            case .thinking:
                if isWakeWordSession {
                    status = snapshot.isDelegationInProgress ? "Consultando o Hermes" : "Pensando..."
                } else {
                    status = snapshot.statusMessage ?? "Thinking..."
                }
            case .speaking:
                status = isWakeWordSession ? "Conversando" : "Speaking"
            default:
                status = snapshot.statusMessage ?? "Connected"
            }
            // Extract tool name from status message if it mentions a tool
            let toolName = snapshot.isDelegationInProgress
                ? "Consultando o Hermes"
                : (snapshot.statusMessage?.contains("working") == true ? snapshot.statusMessage : nil)
            liveActivity.updateVoiceState(status, toolName: toolName)
        }

        onSessionStateChanged?()
    }
}
