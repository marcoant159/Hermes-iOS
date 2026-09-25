@preconcurrency import AVFoundation
import Foundation
import Darwin
import os

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@MainActor
final class LiveVoiceSessionService: NSObject, VoiceSessionServiceProtocol {
    private static let logger = Logger(subsystem: "br.com.marcoant.hermes", category: "LiveVoiceSessionService")
    private struct EmptyBody: Encodable {}

    private struct EmptyRelayResponse: Decodable {}

    private struct TalkReadinessResponse: Decodable {
        let ready: Bool
        let hostOnline: Bool
        let configured: Bool
        let blockedReason: String?
        let preferredModels: [String]?
        let selectedModel: String?
        let voice: String?
        let voiceContextUpdatedAt: Date?
    }

    private struct TalkSessionResponse: Decodable {
        let voiceSession: RelayVoiceSession
        let bootstrap: TalkBootstrap
    }

    private struct RelayVoiceSession: Decodable {
        let id: UUID
        let status: String
        let model: String?
        let voice: String?
        let startedAt: Date
        let endedAt: Date?
        let lastError: String?
    }

    private struct TalkBootstrap: Decodable {
        let clientSecret: String?
        let expiresAt: Date?
        let session: RealtimeSession
        let model: String?
        let voice: String?
        let provider: String?
        let relayMcpURL: String?
        let systemInstruction: String?
    }

    private struct TalkSessionCreateRequest: Encodable {
        let provider: String
    }

    private struct SDPExchangeRequest: Encodable {
        let sdp: String
    }

    private struct SDPExchangeResponse: Decodable {
        let sdp: String
        let callId: String?
    }

    private struct RealtimeSession: Decodable {
        let id: String?
    }

    private struct VoiceTurnCreateRequest: Encodable {
        let clientTurnId: UUID
        let role: String
        let source: String
        let text: String
    }

    private struct VoiceTurnPersistResponse: Decodable {
        let turn: PersistedTurn
    }

    private struct PersistedTurn: Decodable {
        let id: UUID
    }

    var voiceState: VoiceState = .idle { didSet { publishSnapshot() } }
    var connectionState: TalkConnectionState = .idle { didSet { publishSnapshot() } }
    var transcriptItems: [TranscriptItem] = [] { didSet { publishSnapshot() } }
    var sessionDuration: TimeInterval = 0 { didSet { publishSnapshot() } }
    var isMuted = false { didSet { publishSnapshot() } }
    var blockedReason: String? { didSet { publishSnapshot() } }
    var statusMessage: String? { didSet { publishSnapshot() } }
    var canStartSession = false { didSet { publishSnapshot() } }
    var latencyMetrics = TalkLatencyMetrics() { didSet { publishSnapshot() } }

    var snapshot: TalkSessionSnapshot {
        TalkSessionSnapshot(
            voiceState: voiceState,
            connectionState: connectionState,
            transcriptItems: transcriptItems,
            sessionDuration: sessionDuration,
            isMuted: isMuted,
            blockedReason: blockedReason,
            statusMessage: statusMessage,
            canStartSession: canStartSession,
            latencyMetrics: latencyMetrics,
            voiceSessionID: voiceSessionID
        )
    }

    private let apiClient: RelayAPIClient
    private let accessTokenProvider: @MainActor () async -> String?
    private let accessTokenRefresher: @MainActor () async -> String?
    private let providerProvider: @MainActor () -> String
    private let urlSession: URLSession
    private let realtimeEventTransportOverride: ((Data) -> Bool)?
    private let eventHub = TalkSessionEventHub()
    private var voiceSessionID: UUID?
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?
    private var transcriptItemIDsByConversationItemID: [String: UUID] = [:]
    private var currentAssistantItemID: UUID?
    private var assistantTextSource: String?
    private var currentRealtimeResponseID: String?
    private var currentAssistantConversationItemID: String?
    private var currentUserConversationItemID: String?
    private var currentAssistantContentIndex = 0
    private var assistantAudioPlaybackStartedAtUptime: TimeInterval?
    private var accumulatedAssistantAudioPlaybackMilliseconds = 0
    private var ignoreCurrentAssistantFinalization = false
    private var lastImageItemID: String?
    private let geminiAudioEngine = AVAudioEngine()
    private let geminiAudioPlayer = AVAudioPlayerNode()
    private var geminiInputConverter: AVAudioConverter?
    private var geminiTapInstalled = false
    private var geminiSocket: URLSessionWebSocketTask?
    private var geminiReceiveTask: Task<Void, Never>?
    private var geminiResumeTask: Task<Void, Never>?
    private var geminiBootstrap: TalkBootstrap?
    private var geminiSessionResumptionHandle: String?
    private var geminiRelayMcpURL: String?
    private var geminiInputTranscript = ""
    private var geminiAssistantTranscript = ""
    private var geminiIgnoreCurrentAudio = false
    fileprivate var isEndingSession = false

    #if canImport(WebRTC)
    private static let peerFactory = RTCPeerConnectionFactory()
    private let peerDelegate = RealtimePeerDelegate()
    nonisolated(unsafe) private var peerConnection: RTCPeerConnection?
    nonisolated(unsafe) private var dataChannel: RTCDataChannel?
    nonisolated(unsafe) private var audioTrack: RTCAudioTrack?
    #endif

    init(
        apiClient: RelayAPIClient,
        accessTokenProvider: @escaping @MainActor () async -> String?,
        accessTokenRefresher: @escaping @MainActor () async -> String? = { nil },
        providerProvider: @escaping @MainActor () -> String = { "auto" },
        urlSession: URLSession = .shared,
        realtimeEventTransportOverride: ((Data) -> Bool)? = nil
    ) {
        self.apiClient = apiClient
        self.accessTokenProvider = accessTokenProvider
        self.accessTokenRefresher = accessTokenRefresher
        self.providerProvider = providerProvider
        self.urlSession = urlSession
        self.realtimeEventTransportOverride = realtimeEventTransportOverride
        super.init()
        geminiAudioEngine.attach(geminiAudioPlayer)
        geminiAudioEngine.connect(geminiAudioPlayer, to: geminiAudioEngine.mainMixerNode, format: nil)
        registerAudioSessionObservers()
        #if canImport(WebRTC)
        peerDelegate.owner = self
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func events() -> AsyncStream<TalkSessionEvent> {
        eventHub.stream(initial: snapshot)
    }

    func refreshReadiness() async {
        // Don't disrupt an active or connecting session with a readiness check.
        if connectionState == .connected || connectionState == .connecting {
            return
        }
        connectionState = .checking
        do {
            let response: TalkReadinessResponse = try await performAuthorizedRequest { [self] in
                let token = await self.accessTokenProvider()
                return try await self.apiClient.get(path: "talk/readiness", accessToken: token)
            }
            blockedReason = response.blockedReason
            canStartSession = response.ready
            statusMessage = response.ready ? "Hermes talk is ready." : (response.blockedReason ?? "Talk is unavailable.")
            connectionState = response.ready ? .ready : .blocked
            if !response.ready {
                voiceState = .disconnected
            }
        } catch {
            blockedReason = error.localizedDescription
            canStartSession = false
            statusMessage = friendlyStatusMessage(for: error)
            connectionState = .failed
            voiceState = .disconnected
        }
    }

    func startSession() async {
        latencyMetrics = TalkLatencyMetrics(sessionStartRequestedAt: .now)
        isEndingSession = false
        // Skip readiness check — already done by VoiceOverlayScreen.task before
        // calling startSession. Removing it saves one HTTP round trip + RPC.
        guard canStartSession else { return }

        guard await ensureMicrophonePermission() else {
            blockedReason = "Microphone access is required for talk mode."
            canStartSession = false
            connectionState = .blocked
            voiceState = .disconnected
            return
        }

        connectionState = .connecting
        voiceState = .thinking
        statusMessage = "Starting talk mode."
        transcriptItems = []
        transcriptItemIDsByConversationItemID = [:]
        currentAssistantItemID = nil
        currentUserConversationItemID = nil
        assistantTextSource = nil

        do {
            try configureAudioSession()
            let response: TalkSessionResponse = try await performAuthorizedRequest { [self] in
                let token = await self.accessTokenProvider()
                return try await self.apiClient.post(
                    path: "talk/session",
                    body: TalkSessionCreateRequest(provider: self.providerProvider()),
                    accessToken: token
                )
            }
            voiceSessionID = response.voiceSession.id
            startedAt = .now
            latencyMetrics.relayBootstrapReceivedAt = .now
            startTimer()
            if response.bootstrap.provider == "gemini_live" {
                try await connectGeminiLive(response.bootstrap)
            } else {
                #if canImport(WebRTC)
                let prepared = try await prepareWebRTC()
                try await connectWithPrepared(prepared, bootstrap: response.bootstrap)
                #else
                try await endRemoteSession()
                blockedReason = "This build does not include the WebRTC client transport yet."
                canStartSession = false
                connectionState = .blocked
                voiceState = .disconnected
                statusMessage = blockedReason
                #endif
            }
        } catch {
            stopGeminiTransport()
            try? await endRemoteSession()
            voiceSessionID = nil
            startedAt = nil
            blockedReason = error.localizedDescription
            canStartSession = false
            connectionState = .failed
            voiceState = .disconnected
            statusMessage = friendlyStatusMessage(for: error)
            stopTimer()
        }
    }

    func endSession() async {
        stopTimer()
        startedAt = nil
        isEndingSession = true
        currentAssistantItemID = nil
        currentUserConversationItemID = nil
        assistantTextSource = nil
        currentRealtimeResponseID = nil
        currentAssistantConversationItemID = nil
        currentAssistantContentIndex = 0
        transcriptItemIDsByConversationItemID = [:]
        resetAssistantAudioPlaybackTracking()
        ignoreCurrentAssistantFinalization = false
        lastImageItemID = nil
        #if canImport(WebRTC)
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        audioTrack = nil
        #endif
        stopGeminiTransport()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? await endRemoteSession()
        voiceSessionID = nil
        voiceState = .idle
        connectionState = .idle
        blockedReason = nil
        canStartSession = true
        statusMessage = nil
    }

    func toggleMute() async {
        isMuted.toggle()
        #if canImport(WebRTC)
        audioTrack?.isEnabled = !isMuted
        #endif
    }

    @discardableResult
    func sendImage(_ imageData: Data, mimeType: String = "image/jpeg", triggerResponse: Bool = true) -> Bool {
        guard connectionState == .connected else { return false }

        if geminiSocket != nil {
            let payload: [String: Any] = [
                "realtimeInput": [
                    "video": [
                        "data": imageData.base64EncodedString(),
                        "mimeType": mimeType,
                    ],
                ],
            ]
            Task { @MainActor [weak self] in
                await self?.sendGeminiMessage(payload)
            }
            transcriptItems.append(TranscriptItem(speaker: .user, text: "", imageData: imageData))
            return true
        }

        // Delete the previous image item so the model only sees the latest one.
        // Without this, the model references stale camera frames or old photos.
        if let previousID = lastImageItemID {
            _ = sendRealtimeEvent([
                "type": "conversation.item.delete",
                "event_id": UUID().uuidString,
                "item_id": previousID,
            ])
            lastImageItemID = nil
        }

        let base64 = imageData.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(base64)"
        let imageItemID = "img\(UUID().uuidString.prefix(28))"

        let sent = sendRealtimeEvent([
            "type": "conversation.item.create",
            "event_id": UUID().uuidString,
            "item": [
                "id": imageItemID,
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": dataURL,
                    ] as [String: Any]
                ],
            ] as [String: Any],
        ])

        if sent {
            lastImageItemID = imageItemID
        }

        if sent && triggerResponse {
            // Only trigger response if no response is already in-flight
            if currentRealtimeResponseID == nil {
                _ = sendRealtimeEvent([
                    "type": "response.create",
                    "event_id": UUID().uuidString,
                ])
            }
            // Add thumbnail to transcript so the user sees what they sent
            transcriptItems.append(TranscriptItem(speaker: .user, text: "", imageData: imageData))
        }

        return sent
    }

    private func publishSnapshot() {
        eventHub.publish(snapshot: snapshot)
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task {
            while !Task.isCancelled {
                if let startedAt {
                    sessionDuration = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func performAuthorizedRequest<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch RelayAPIClient.ClientError.unauthorized {
            // accessTokenRefresher() persists the new token to SessionStore.
            // The retry calls accessTokenProvider() which reads from the same store,
            // so it will pick up the refreshed token automatically.
            guard let refreshedToken = await accessTokenRefresher(), !refreshedToken.isEmpty else {
                throw RelayAPIClient.ClientError.unauthorized("Expired or invalid access token.")
            }
            return try await operation()
        }
    }

    private func friendlyStatusMessage(for error: Error) -> String {
        if case RelayAPIClient.ClientError.unauthorized = error {
            return "Your Hermes session expired. Reconnect or try again."
        }
        return "Could not reach the relay."
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        sessionDuration = 0
    }

    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private var hasActiveRealtimeSession: Bool {
        voiceSessionID != nil || connectionState == .connected || connectionState == .connecting
    }

    @objc
    private nonisolated func handleAudioSessionInterruptionNotification(_ notification: Notification) {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0

        Task { @MainActor [weak self] in
            guard let self,
                  let rawType,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType)
            else {
                return
            }

            switch interruptionType {
            case .began:
                self.handleAudioInterruptionBegan()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self.handleAudioInterruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                break
            }
        }
    }

    @objc
    private nonisolated func handleAudioSessionRouteChangeNotification(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt

        Task { @MainActor [weak self] in
            guard let self,
                  let rawReason,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            else {
                return
            }
            self.handleAudioRouteChange(reason)
        }
    }

    func handleAudioInterruptionBegan() {
        guard hasActiveRealtimeSession else { return }
        stopAssistantAudioPlaybackTracking()
        voiceState = .interrupted
        statusMessage = "Audio interrupted."
    }

    func handleAudioInterruptionEnded(shouldResume: Bool) {
        guard hasActiveRealtimeSession else { return }
        guard shouldResume else {
            statusMessage = "Audio interrupted."
            return
        }

        do {
            try configureAudioSession()
            if geminiSocket != nil, !geminiAudioEngine.isRunning {
                try geminiAudioEngine.start()
                if !geminiAudioPlayer.isPlaying { geminiAudioPlayer.play() }
            }
            if connectionState == .connected || connectionState == .connecting {
                voiceState = .listening
                statusMessage = "Listening"
            }
        } catch {
            Self.logger.warning("Failed to reactivate audio session after interruption: \(error.localizedDescription)")
            connectionState = .failed
            voiceState = .disconnected
            statusMessage = "Audio session could not resume."
        }
    }

    func handleAudioRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard hasActiveRealtimeSession else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange, .categoryChange:
            if voiceState == .interrupted {
                voiceState = .listening
            }
            statusMessage = "Audio route changed."
            // Re-assert speaker output when a device is removed (e.g. headphones unplugged)
            // or the route is reconfigured by the system / WebRTC.
            forceSpeakerIfNeeded()
        default:
            break
        }
    }

    private func endRemoteSession() async throws {
        guard let voiceSessionID else { return }
        let _: EmptyRelayResponse = try await performAuthorizedRequest { [self] in
            let token = await self.accessTokenProvider()
            return try await self.apiClient.post(
                path: "talk/session/\(voiceSessionID.uuidString.lowercased())/end",
                body: EmptyBody(),
                accessToken: token
            )
        }
    }

    private func persistFinalTurn(
        clientTurnID: UUID,
        speaker: TranscriptSpeaker,
        text: String
    ) {
        guard let voiceSessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.performAuthorizedRequest { [self] in
                let token = await self.accessTokenProvider()
                return try await self.apiClient.post(
                    path: "talk/session/\(voiceSessionID.uuidString.lowercased())/turns",
                    body: VoiceTurnCreateRequest(
                        clientTurnId: clientTurnID,
                        role: speaker.rawValue,
                        source: "realtime",
                        text: trimmed
                    ),
                    accessToken: token
                ) as VoiceTurnPersistResponse
            }
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try audioSession.setActive(true)

        // Force output to the speaker for maximum volume — but only when no
        // headphones or Bluetooth audio device is connected. Headsets handle
        // their own volume and don't need the override.
        let hasExternalOutput = audioSession.currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio]
                .contains(output.portType)
        }
        if !hasExternalOutput {
            try audioSession.overrideOutputAudioPort(.speaker)
        }
    }

    /// Re-assert the speaker override after WebRTC (or any other subsystem) may
    /// have reset the audio route.  Safe to call at any time — skips the override
    /// when headphones, Bluetooth, AirPlay, or CarPlay are connected.
    private func forceSpeakerIfNeeded() {
        let audioSession = AVAudioSession.sharedInstance()
        let hasExternalOutput = audioSession.currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio]
                .contains(output.portType)
        }
        guard !hasExternalOutput else { return }
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
        } catch {
            Self.logger.warning("forceSpeakerIfNeeded: override failed — \(error.localizedDescription)")
        }
    }

    func handleDataChannelEvent(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            handleServerVADInterruption()
            voiceState = .listening
            statusMessage = "Listening"
        case "input_audio_buffer.committed":
            createPendingUserTranscriptItem(from: payload)
        case "conversation.item.created",  // beta
             "conversation.item.added":      // GA
            if let item = payload["item"] as? [String: Any],
               let role = item["role"] as? String,
               role == "assistant",
               let itemID = item["id"] as? String {
                currentAssistantConversationItemID = itemID
                currentAssistantContentIndex = 0
                resetAssistantAudioPlaybackTracking()
                ignoreCurrentAssistantFinalization = false
            }
        case "conversation.item.truncated":
            stopAssistantAudioPlaybackTracking()
            currentAssistantConversationItemID = nil
            currentRealtimeResponseID = nil
            voiceState = .listening
            statusMessage = "Listening"
        case "output_audio_buffer.started":
            startAssistantAudioPlaybackTracking()
            voiceState = .speaking
            statusMessage = "Hermes is speaking."
        case "output_audio_buffer.stopped":
            stopAssistantAudioPlaybackTracking()
            currentRealtimeResponseID = nil
            voiceState = .listening
            statusMessage = "Listening"
        case "output_audio_buffer.cleared":
            stopAssistantAudioPlaybackTracking()
            currentRealtimeResponseID = nil
            voiceState = .listening
            statusMessage = "Listening"
        case "response.created":
            currentRealtimeResponseID = ((payload["response"] as? [String: Any])?["id"] as? String)
            ignoreCurrentAssistantFinalization = false
            voiceState = .thinking
            statusMessage = "Hermes is thinking."
        case "response.function_call_arguments.delta",
             "response.function_call_arguments.done",
             "response.mcp_call_arguments.delta",
             "response.mcp_call_arguments.done",
             "response.mcp_call.in_progress":
            // Tool or MCP call in progress — show "working on it" state
            if voiceState != .thinking {
                voiceState = .thinking
            }
            statusMessage = "Hermes is working on that\u{2026}"
        case "response.mcp_call.completed":
            // MCP tool call finished — trigger a new response so the model speaks the result.
            // The response lifecycle completes BEFORE the MCP call executes, so no automatic
            // follow-up audio is generated. We must explicitly request one.
            if currentRealtimeResponseID == nil {
                _ = sendRealtimeEvent([
                    "type": "response.create",
                    "event_id": UUID().uuidString,
                ])
                voiceState = .thinking
                statusMessage = "Hermes has the answer\u{2026}"
            }
        case "response.mcp_call.failed":
            statusMessage = "A tool call failed — Hermes will try another way."
        case "response.done":
            let doneResponse = payload["response"] as? [String: Any]
            let status = doneResponse?["status"] as? String
            // If the response completed with tool calls (not "completed"), keep thinking
            // until the next response starts with the tool result.
            if status == "completed" {
                currentRealtimeResponseID = nil
            }
        case "response.audio_transcript.delta",              // beta
             "response.output_audio_transcript.delta":         // GA
            assistantTextSource = assistantTextSource ?? "audio"
            if assistantTextSource == "audio" {
                appendAssistantDelta(payload["delta"] as? String ?? "")
            }
        case "response.output_text.delta":
            assistantTextSource = assistantTextSource ?? "text"
            if assistantTextSource == "text" {
                appendAssistantDelta(payload["delta"] as? String ?? "")
            }
        case "response.audio_transcript.done",               // beta
             "response.output_audio_transcript.done":          // GA
            assistantTextSource = assistantTextSource ?? "audio"
            if assistantTextSource == "audio" {
                finalizeAssistantText(payload["transcript"] as? String ?? payload["text"] as? String)
            }
        case "response.output_text.done":
            assistantTextSource = assistantTextSource ?? "text"
            if assistantTextSource == "text" {
                finalizeAssistantText(payload["transcript"] as? String ?? payload["text"] as? String)
            }
        case "conversation.item.input_audio_transcription.delta":
            updateUserTranscriptDelta(
                for: payload["item_id"] as? String,
                delta: payload["delta"] as? String ?? ""
            )
        case "conversation.item.input_audio_transcription.completed":
            finalizeUserText(
                itemID: payload["item_id"] as? String,
                finalText: payload["transcript"] as? String ?? ""
            )
        case "error":
            if isEndingSession {
                break
            }
            let message = ((payload["error"] as? [String: Any])?["message"] as? String) ?? "Realtime talk failed."
            // Suppress transient "active response in progress" errors — these are harmless
            // race conditions from our response.create after MCP tool completion.
            if message.contains("active response in progress") {
                break
            }
            blockedReason = message
            connectionState = .failed
            voiceState = .disconnected
            statusMessage = message
        default:
            break
        }
    }

    #if canImport(WebRTC)
    private struct PreparedWebRTC {
        let connection: RTCPeerConnection
        let channel: RTCDataChannel?
        let track: RTCAudioTrack
        let offerSDP: String
    }

    /// Phase 1: Create peer connection, audio track, data channel, and generate SDP offer.
    /// Can run in parallel with the relay bootstrap request.
    private func prepareWebRTC() async throws -> PreparedWebRTC {
        let rtcConfig = RTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.peerFactory.peerConnection(with: rtcConfig, constraints: constraints, delegate: peerDelegate) else {
            throw RelayAPIClient.ClientError.requestFailed("Failed to create WebRTC peer connection.")
        }
        let audioSource = Self.peerFactory.audioSource(with: constraints)
        let track = Self.peerFactory.audioTrack(with: audioSource, trackId: "hermes-mobile-audio")
        _ = connection.add(track, streamIds: ["hermes-mobile-stream"])
        let dataChannelConfig = RTCDataChannelConfiguration()
        let channel = connection.dataChannel(forLabel: "oai-events", configuration: dataChannelConfig)
        channel?.delegate = peerDelegate

        let offer = try await connection.createOfferAsync()
        try await connection.setLocalDescriptionAsync(offer)

        return PreparedWebRTC(connection: connection, channel: channel, track: track, offerSDP: offer.sdp)
    }

    /// Phase 2: Exchange SDP with the ephemeral key and complete the connection.
    private func connectWithPrepared(_ prepared: PreparedWebRTC, bootstrap: TalkBootstrap) async throws {
        peerConnection = prepared.connection
        dataChannel = prepared.channel
        audioTrack = prepared.track
        audioTrack?.isEnabled = !isMuted

        let answerSDP: String
        if bootstrap.provider == "codex_realtime" {
            answerSDP = try await exchangeRelaySDP(localSDP: prepared.offerSDP)
        } else {
            guard let clientSecret = bootstrap.clientSecret else {
                throw RelayAPIClient.ClientError.requestFailed("OpenAI Realtime session is missing its client secret.")
            }
            answerSDP = try await exchangeSDP(
                localSDP: prepared.offerSDP,
                clientSecret: clientSecret,
                model: bootstrap.model
            )
        }
        let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await prepared.connection.setRemoteDescriptionAsync(answer)

        latencyMetrics.realtimeConnectedAt = .now
        connectionState = .connected
        voiceState = .listening
        blockedReason = nil
        canStartSession = true
        statusMessage = "Listening"

        // Re-assert speaker override AFTER WebRTC finishes its audio setup.
        // WebRTC's RTCPeerConnectionFactory reconfigures the audio session
        // internally, which can reset our overrideOutputAudioPort(.speaker).
        forceSpeakerIfNeeded()

        // WebRTC may continue adjusting the audio route asynchronously after
        // setRemoteDescription returns. Fire another override after a short
        // delay as a safety net.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.forceSpeakerIfNeeded()
        }
    }

    private func exchangeSDP(localSDP: String, clientSecret: String, model: String?) async throws -> String {
        let modelName = model ?? "gpt-realtime"
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls?model=\(modelName)") else {
            throw RelayAPIClient.ClientError.invalidURL("https://api.openai.com/v1/realtime/calls")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.upload(for: request, from: Data(localSDP.utf8))
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RelayAPIClient.ClientError.requestFailed(String(data: data, encoding: .utf8) ?? "OpenAI Realtime SDP exchange failed.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Exchanges the SDP offer through the relay for providers that keep
    /// credentials on the Hermes host (e.g. "GPT Realtime via Codex").
    private func exchangeRelaySDP(localSDP: String) async throws -> String {
        guard let voiceSessionID else {
            throw RelayAPIClient.ClientError.requestFailed("Talk session is not available for SDP exchange.")
        }
        let response: SDPExchangeResponse = try await performAuthorizedRequest { [self] in
            let token = await self.accessTokenProvider()
            return try await self.apiClient.post(
                path: "talk/session/\(voiceSessionID.uuidString.lowercased())/sdp",
                body: SDPExchangeRequest(sdp: localSDP),
                accessToken: token
            )
        }
        return response.sdp
    }
    #endif

    private func connectGeminiLive(_ bootstrap: TalkBootstrap, resumptionHandle: String? = nil) async throws {
        guard let mcpURL = bootstrap.relayMcpURL,
              let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")
        else {
            throw RelayAPIClient.ClientError.requestFailed("Gemini Live session configuration is incomplete.")
        }
        geminiBootstrap = bootstrap

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "access_token", value: bootstrap.clientSecret)]
        guard let socketURL = components?.url else {
            throw RelayAPIClient.ClientError.invalidURL(endpoint.absoluteString)
        }

        geminiRelayMcpURL = mcpURL
        geminiSocket = urlSession.webSocketTask(with: socketURL)
        guard let socket = geminiSocket else {
            throw RelayAPIClient.ClientError.requestFailed("Could not create Gemini Live WebSocket.")
        }
        socket.resume()

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(bootstrap.model ?? "gemini-3.8-live")",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": bootstrap.voice ?? "Aoede"]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [["text": bootstrap.systemInstruction ?? "Speak naturally in Brazilian Portuguese."]]
                ],
                "inputAudioTranscription": ["languageCodes": ["pt-BR"]],
                "outputAudioTranscription": ["languageCodes": ["pt-BR"]],
                "sessionResumption": resumptionHandle.map { ["handle": $0] } ?? [:],
                "tools": [[
                    "functionDeclarations": [[
                        "name": "hermes_delegate",
                        "description": "Delegate a voice request to the connected Hermes host. Use this when the user asks for something that requires tool access, file reads, memory lookups, or an action beyond what your cached context provides.",
                        "parameters": [
                            "type": "OBJECT",
                            "properties": [
                                "prompt": [
                                    "type": "STRING",
                                    "description": "The user's request for Hermes."
                                ]
                            ],
                            "required": ["prompt"]
                        ]
                    ]]
                ]]
            ]
        ]
        let setupData = try JSONSerialization.data(withJSONObject: setup)
        guard let setupMessage = String(data: setupData, encoding: .utf8) else {
            throw RelayAPIClient.ClientError.requestFailed("Could not encode Gemini Live setup.")
        }
        try await socket.send(.string(setupMessage))

        let initialMessage = try await socket.receive()
        let initialPayload = try decodeGeminiMessage(initialMessage)
        if let error = initialPayload["error"] as? [String: Any] {
            throw RelayAPIClient.ClientError.requestFailed(error["message"] as? String ?? "Gemini Live setup failed.")
        }
        guard initialPayload["setupComplete"] != nil else {
            throw RelayAPIClient.ClientError.requestFailed("Gemini Live did not confirm the session setup.")
        }
        updateGeminiSessionResumption(from: initialPayload)

        try startGeminiAudioCapture()
        try geminiAudioEngine.start()
        if !geminiAudioPlayer.isPlaying { geminiAudioPlayer.play() }
        latencyMetrics.realtimeConnectedAt = .now
        connectionState = .connected
        voiceState = .listening
        blockedReason = nil
        canStartSession = true
        statusMessage = "Listening with Gemini Live"
        forceSpeakerIfNeeded()

        geminiReceiveTask = Task { @MainActor [weak self] in
            await self?.receiveGeminiMessages(from: socket)
        }
    }

    private func startGeminiAudioCapture() throws {
        let inputNode = geminiAudioEngine.inputNode
        if geminiTapInstalled {
            inputNode.removeTap(onBus: 0)
            geminiTapInstalled = false
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RelayAPIClient.ClientError.requestFailed("Could not prepare Gemini microphone audio format.")
        }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.primeMethod = .none
        geminiInputConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let converter,
                  let converted = Self.convertGeminiInput(buffer, converter: converter, format: outputFormat),
                  let samples = converted.int16ChannelData?.pointee
            else { return }
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let audioData = Data(bytes: samples, count: byteCount)
            Task { @MainActor [weak self] in
                guard let self, !self.isMuted else { return }
                await self.sendGeminiAudio(audioData)
            }
        }
        geminiTapInstalled = true
        geminiAudioEngine.prepare()
    }

    private nonisolated static func convertGeminiInput(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        final class ConversionState: @unchecked Sendable {
            var didProvideInput = false
        }

        let frameRatio = format.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * frameRatio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            return nil
        }
        let state = ConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if state.didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func sendGeminiAudio(_ audioData: Data) async {
        guard geminiSocket != nil, !audioData.isEmpty else { return }
        await sendGeminiMessage([
            "realtimeInput": [
                "audio": [
                    "data": audioData.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    private func sendGeminiMessage(_ payload: [String: Any]) async {
        guard let socket = geminiSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await socket.send(.string(message))
        } catch {
            Self.logger.error("Gemini Live send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receiveGeminiMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, !isEndingSession {
                let message = try await socket.receive()
                let payload = try decodeGeminiMessage(message)
                await handleGeminiMessage(payload)
            }
        } catch {
            guard !isEndingSession else { return }
            // A socket that has already been replaced (e.g. we are mid-resume) can
            // fail late. Ignore it so it cannot clobber the connection taking
            // over; only the current socket's failure is actionable.
            guard socket === geminiSocket else { return }
            // Proactively resume only when no resume is already in flight.
            if geminiResumeTask == nil, geminiSessionResumptionHandle != nil {
                scheduleGeminiResume()
                return
            }
            // The live socket failed and cannot be resumed (or the resume that
            // was in flight also failed): surface it so the caller stops
            // treating the session as alive and can re-arm the wake word.
            blockedReason = error.localizedDescription
            connectionState = .failed
            voiceState = .disconnected
            canStartSession = false
            statusMessage = "Gemini Live disconnected."
        }
    }

    private func decodeGeminiMessage(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default:
            throw RelayAPIClient.ClientError.requestFailed("Unsupported Gemini Live message format.")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayAPIClient.ClientError.requestFailed("Gemini Live returned an invalid message.")
        }
        return payload
    }

    private func handleGeminiMessage(_ payload: [String: Any]) async {
        updateGeminiSessionResumption(from: payload)
        if payload["goAway"] != nil {
            scheduleGeminiResume()
            return
        }

        if let error = payload["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Gemini Live returned an error."
            blockedReason = message
            connectionState = .failed
            voiceState = .disconnected
            statusMessage = message
            return
        }

        if let toolCall = payload["toolCall"] as? [String: Any] {
            await handleGeminiToolCall(toolCall)
        }
        guard let serverContent = payload["serverContent"] as? [String: Any] else { return }

        if let input = serverContent["inputTranscription"] as? [String: Any],
           let text = input["text"] as? String {
            // Gemini streams the user transcription in several chunks. Keep
            // accumulating them and only finalize when the turn actually ends
            // (turnComplete), so one utterance stays a single TranscriptItem.
            appendGeminiUserTranscript(text)
        }
        if let output = serverContent["outputTranscription"] as? [String: Any],
           let text = output["text"] as? String,
           !geminiIgnoreCurrentAudio {
            geminiAssistantTranscript += text
            assistantTextSource = "audio"
            appendAssistantDelta(text)
        }
        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let base64 = inlineData["data"] as? String,
                      let audioData = Data(base64Encoded: base64)
                else { continue }
                scheduleGeminiAudio(audioData)
            }
        }
        if serverContent["interrupted"] as? Bool == true {
            geminiAudioPlayer.stop()
            geminiAudioPlayer.play()
            geminiIgnoreCurrentAudio = false
            voiceState = .listening
            statusMessage = "Listening"
        }
        if serverContent["turnComplete"] as? Bool == true {
            if !geminiInputTranscript.isEmpty {
                finalizeUserText(itemID: currentUserConversationItemID, finalText: geminiInputTranscript)
                geminiInputTranscript = ""
            }
            finalizeAssistantText(geminiAssistantTranscript)
            geminiAssistantTranscript = ""
            geminiIgnoreCurrentAudio = false
            voiceState = .listening
            statusMessage = "Listening with Gemini Live"
        } else if serverContent["generationComplete"] as? Bool == true {
            voiceState = .listening
            statusMessage = "Listening with Gemini Live"
        }
    }

    private func updateGeminiSessionResumption(from payload: [String: Any]) {
        guard let update = payload["sessionResumptionUpdate"] as? [String: Any] else { return }
        guard update["resumable"] as? Bool == true,
              let handle = update["newHandle"] as? String,
              !handle.isEmpty
        else {
            geminiSessionResumptionHandle = nil
            return
        }
        geminiSessionResumptionHandle = handle
    }

    private func scheduleGeminiResume() {
        guard !isEndingSession,
              geminiResumeTask == nil,
              let bootstrap = geminiBootstrap,
              let handle = geminiSessionResumptionHandle
        else {
            if !isEndingSession, geminiSessionResumptionHandle == nil {
                blockedReason = "Gemini Live could not resume because no resumable checkpoint was available."
                connectionState = .failed
                voiceState = .disconnected
                canStartSession = false
                statusMessage = "Gemini Live session ended."
            }
            return
        }

        connectionState = .connecting
        voiceState = .thinking
        statusMessage = "Resuming Gemini Live…"
        geminiAudioEngine.stop()
        geminiSocket?.cancel(with: .goingAway, reason: nil)
        geminiSocket = nil

        geminiResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Always clear the resume marker, including on early return/cancel,
            // so a later receive failure is never masked by a stale task.
            defer { self.geminiResumeTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, !self.isEndingSession else { return }
                try await self.connectGeminiLive(bootstrap, resumptionHandle: handle)
            } catch {
                guard !self.isEndingSession else { return }
                self.blockedReason = error.localizedDescription
                self.connectionState = .failed
                self.voiceState = .disconnected
                self.canStartSession = false
                self.statusMessage = "Gemini Live could not resume."
            }
        }
    }

    private func appendGeminiUserTranscript(_ delta: String) {
        guard !delta.isEmpty else { return }
        geminiInputTranscript += delta
        if currentUserConversationItemID == nil {
            let itemID = "gemini-\(UUID().uuidString)"
            let placeholder = TranscriptItem(speaker: .user, text: "\u{2026}", isPartial: true)
            currentUserConversationItemID = itemID
            transcriptItemIDsByConversationItemID[itemID] = placeholder.id
            transcriptItems.append(placeholder)
        }
        updateUserTranscriptDelta(for: currentUserConversationItemID, delta: delta)
    }

    private func scheduleGeminiAudio(_ data: Data) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else { return }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.int16ChannelData?.pointee,
              !geminiIgnoreCurrentAudio
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                memcpy(samples, source, data.count)
            }
        }
        geminiAudioPlayer.scheduleBuffer(buffer, completionHandler: nil)
        if !geminiAudioPlayer.isPlaying {
            geminiAudioPlayer.play()
        }
        voiceState = .speaking
        statusMessage = "Gemini is speaking."
    }

    private func handleGeminiToolCall(_ toolCall: [String: Any]) async {
        guard let calls = toolCall["functionCalls"] as? [[String: Any]], !calls.isEmpty else { return }
        voiceState = .thinking
        statusMessage = "Hermes is working on that…"
        var responses: [[String: Any]] = []
        for call in calls {
            let callID = call["id"] as? String ?? UUID().uuidString
            let name = call["name"] as? String ?? "hermes_delegate"
            let arguments = call["args"] as? [String: Any] ?? [:]
            let prompt = arguments["prompt"] as? String ?? ""
            do {
                let result = try await callHermesDelegate(prompt)
                responses.append(["id": callID, "name": name, "response": ["result": result]])
            } catch {
                responses.append(["id": callID, "name": name, "response": ["error": error.localizedDescription]])
            }
        }
        await sendGeminiMessage(["toolResponse": ["functionResponses": responses]])
    }

    private func callHermesDelegate(_ prompt: String) async throws -> String {
        guard let relayURL = geminiRelayMcpURL, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: relayURL)
        else {
            throw RelayAPIClient.ClientError.requestFailed("Hermes tool delegation is unavailable.")
        }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": "hermes_delegate", "arguments": ["prompt": prompt]]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RelayAPIClient.ClientError.requestFailed("Hermes delegation request failed.")
        }
        if let error = payload["error"] as? [String: Any] {
            throw RelayAPIClient.ClientError.requestFailed(error["message"] as? String ?? "Hermes delegation failed.")
        }
        let result = payload["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "Hermes returned no text."
    }

    private func stopGeminiTransport() {
        geminiResumeTask?.cancel()
        geminiResumeTask = nil
        geminiReceiveTask?.cancel()
        geminiReceiveTask = nil
        geminiSocket?.cancel(with: .goingAway, reason: nil)
        geminiSocket = nil
        geminiBootstrap = nil
        geminiSessionResumptionHandle = nil
        geminiRelayMcpURL = nil
        geminiInputTranscript = ""
        geminiAssistantTranscript = ""
        geminiIgnoreCurrentAudio = false
        geminiInputConverter = nil
        if geminiTapInstalled {
            geminiAudioEngine.inputNode.removeTap(onBus: 0)
            geminiTapInstalled = false
        }
        geminiAudioPlayer.stop()
        geminiAudioEngine.stop()
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let currentAssistantItemID,
           let index = transcriptItems.firstIndex(where: { $0.id == currentAssistantItemID }) {
            transcriptItems[index].text += delta
            transcriptItems[index].isPartial = true
        } else {
            let item = TranscriptItem(speaker: .hermes, text: delta, isPartial: true)
            currentAssistantItemID = item.id
            if let currentAssistantConversationItemID {
                transcriptItemIDsByConversationItemID[currentAssistantConversationItemID] = item.id
            }
            transcriptItems.append(item)
        }
    }

    private func finalizeAssistantText(_ finalText: String?) {
        if ignoreCurrentAssistantFinalization && currentAssistantItemID == nil {
            ignoreCurrentAssistantFinalization = false
            currentRealtimeResponseID = nil
            currentAssistantConversationItemID = nil
            assistantTextSource = nil
            voiceState = .listening
            statusMessage = "Listening"
            return
        }

        let text = (finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let turnID: UUID?
        if let currentAssistantItemID,
           let index = transcriptItems.firstIndex(where: { $0.id == currentAssistantItemID }) {
            if !text.isEmpty {
                transcriptItems[index].text = text
            }
            transcriptItems[index].isPartial = false
            turnID = transcriptItems[index].id
            if let currentAssistantConversationItemID {
                transcriptItemIDsByConversationItemID[currentAssistantConversationItemID] = transcriptItems[index].id
            }
        } else if let last = transcriptItems.last,
                  last.speaker == .hermes,
                  !last.isPartial,
                  last.text == text {
            turnID = nil
        } else if !text.isEmpty {
            let item = TranscriptItem(speaker: .hermes, text: text, isPartial: false)
            transcriptItems.append(item)
            turnID = item.id
            if let currentAssistantConversationItemID {
                transcriptItemIDsByConversationItemID[currentAssistantConversationItemID] = item.id
            }
        } else {
            turnID = nil
        }
        currentAssistantItemID = nil
        currentAssistantConversationItemID = nil
        currentRealtimeResponseID = nil
        assistantTextSource = nil
        ignoreCurrentAssistantFinalization = false
        resetAssistantAudioPlaybackTracking()
        if latencyMetrics.firstAssistantFinalizedAt == nil {
            latencyMetrics.firstAssistantFinalizedAt = .now
        }
        if let turnID {
            persistFinalTurn(clientTurnID: turnID, speaker: .hermes, text: text)
        }
        voiceState = .listening
        statusMessage = "Listening"
    }

    private func createPendingUserTranscriptItem(from payload: [String: Any]) {
        let itemID = (payload["item_id"] as? String) ?? ((payload["item"] as? [String: Any])?["id"] as? String)
        guard let itemID else { return }
        currentUserConversationItemID = itemID
        guard transcriptItemIDsByConversationItemID[itemID] == nil else { return }

        let placeholder = TranscriptItem(speaker: .user, text: "\u{2026}", isPartial: true)
        let insertIndex: Int
        if let previousItemID = payload["previous_item_id"] as? String,
           let previousTranscriptID = transcriptItemIDsByConversationItemID[previousItemID],
           let previousIndex = transcriptItems.firstIndex(where: { $0.id == previousTranscriptID }) {
            insertIndex = min(previousIndex + 1, transcriptItems.count)
        } else {
            insertIndex = transcriptItems.count
        }

        transcriptItems.insert(placeholder, at: insertIndex)
        transcriptItemIDsByConversationItemID[itemID] = placeholder.id
    }

    private func updateUserTranscriptDelta(for itemID: String?, delta: String) {
        guard !delta.isEmpty,
              let itemID,
              let transcriptID = transcriptItemIDsByConversationItemID[itemID],
              let index = transcriptItems.firstIndex(where: { $0.id == transcriptID }) else {
            return
        }
        if transcriptItems[index].text == "\u{2026}" {
            transcriptItems[index].text = delta
        } else {
            transcriptItems[index].text += delta
        }
        transcriptItems[index].isPartial = true
    }

    private func finalizeUserText(itemID: String?, finalText: String) {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedItemID = itemID ?? currentUserConversationItemID
        if text.isEmpty {
            if let resolvedItemID,
               let transcriptID = transcriptItemIDsByConversationItemID.removeValue(forKey: resolvedItemID),
               let index = transcriptItems.firstIndex(where: { $0.id == transcriptID }) {
                transcriptItems.remove(at: index)
            }
            currentUserConversationItemID = nil
            return
        }
        let turnID: UUID
        if let resolvedItemID,
           let transcriptID = transcriptItemIDsByConversationItemID[resolvedItemID],
           let index = transcriptItems.firstIndex(where: { $0.id == transcriptID }) {
            transcriptItems[index].text = text
            transcriptItems[index].isPartial = false
            turnID = transcriptItems[index].id
        } else if let last = transcriptItems.last,
                  last.speaker == .user,
                  !last.isPartial,
                  last.text == text {
            return
        } else {
            let item = TranscriptItem(speaker: .user, text: text, isPartial: false)
            transcriptItems.append(item)
            turnID = item.id
            if let resolvedItemID {
                transcriptItemIDsByConversationItemID[resolvedItemID] = item.id
            }
        }
        currentUserConversationItemID = nil
        if latencyMetrics.firstUserFinalizedAt == nil {
            latencyMetrics.firstUserFinalizedAt = .now
        }
        persistFinalTurn(clientTurnID: turnID, speaker: .user, text: text)
        voiceState = .thinking
        statusMessage = "Hermes is thinking."
    }

    private func startAssistantAudioPlaybackTracking() {
        if assistantAudioPlaybackStartedAtUptime == nil {
            assistantAudioPlaybackStartedAtUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    private func stopAssistantAudioPlaybackTracking() {
        accumulatedAssistantAudioPlaybackMilliseconds = currentAssistantAudioPlaybackMilliseconds()
        assistantAudioPlaybackStartedAtUptime = nil
    }

    private func resetAssistantAudioPlaybackTracking() {
        assistantAudioPlaybackStartedAtUptime = nil
        accumulatedAssistantAudioPlaybackMilliseconds = 0
    }

    private func currentAssistantAudioPlaybackMilliseconds() -> Int {
        guard let startedAt = assistantAudioPlaybackStartedAtUptime else {
            return accumulatedAssistantAudioPlaybackMilliseconds
        }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        return accumulatedAssistantAudioPlaybackMilliseconds + Int((elapsed * 1000).rounded())
    }

    /// Called when server VAD detects user speech (`input_audio_buffer.speech_started`).
    ///
    /// The session config already enables `interrupt_response`, which asks the server
    /// to automatically cancel the in-flight response on VAD start. The client still
    /// needs to cut off any buffered playback locally and truncate the assistant item
    /// to the portion the user actually heard.
    private func handleServerVADInterruption() {
        guard voiceState == .speaking || assistantAudioPlaybackStartedAtUptime != nil else { return }
        interruptAssistantOutput(sendCancelAndClear: true)
    }

    /// Called when the user explicitly requests interruption (e.g., a stop button).
    ///
    /// Unlike VAD-triggered interruption, the server has NOT auto-cancelled, so we
    /// must send the full sequence: cancel → clear → truncate.
    func manuallyInterruptAssistantOutput() {
        guard voiceState == .speaking || assistantAudioPlaybackStartedAtUptime != nil else { return }
        if geminiSocket != nil {
            geminiAudioPlayer.stop()
            geminiAudioPlayer.play()
            geminiIgnoreCurrentAudio = true
            voiceState = .listening
            statusMessage = "Listening with Gemini Live"
            return
        }
        interruptAssistantOutput(sendCancelAndClear: true)
        voiceState = .listening
        statusMessage = "Listening"
    }

    private func interruptAssistantOutput(sendCancelAndClear: Bool) {
        if sendCancelAndClear, let responseID = currentRealtimeResponseID {
            if !sendRealtimeEvent([
                "type": "response.cancel",
                "event_id": UUID().uuidString,
                "response_id": responseID,
            ]) {
                Self.logger.warning("Failed to send response.cancel for response \(responseID)")
            }
        }

        if sendCancelAndClear, !sendRealtimeEvent([
            "type": "output_audio_buffer.clear",
            "event_id": UUID().uuidString,
        ]) {
            Self.logger.warning("Failed to send output_audio_buffer.clear")
        }

        truncateAndCleanUpAssistantState()
    }

    /// Shared cleanup: sends `conversation.item.truncate` and resets local tracking state.
    private func truncateAndCleanUpAssistantState() {
        if let itemID = currentAssistantConversationItemID {
            let audioMs = currentAssistantAudioPlaybackMilliseconds()
            if !sendRealtimeEvent([
                "type": "conversation.item.truncate",
                "event_id": UUID().uuidString,
                "item_id": itemID,
                "content_index": currentAssistantContentIndex,
                "audio_end_ms": audioMs,
            ]) {
                Self.logger.warning("Failed to send conversation.item.truncate for item \(itemID) at \(audioMs)ms")
            }
        }

        stopAssistantAudioPlaybackTracking()
        freezeCurrentAssistantTurnForInterruption()
        currentRealtimeResponseID = nil
        currentAssistantConversationItemID = nil
    }

    private func freezeCurrentAssistantTurnForInterruption() {
        if let currentAssistantItemID,
           let index = transcriptItems.firstIndex(where: { $0.id == currentAssistantItemID }) {
            transcriptItems[index].isPartial = false
            if let currentAssistantConversationItemID {
                transcriptItemIDsByConversationItemID[currentAssistantConversationItemID] = currentAssistantItemID
            }
        }
        currentAssistantItemID = nil
        assistantTextSource = nil
        ignoreCurrentAssistantFinalization = true
    }

    private func sendRealtimeEvent(_ payload: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(payload) else {
            Self.logger.warning("Realtime event payload was not valid JSON: \(String(describing: payload["type"]))")
            return false
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            if let realtimeEventTransportOverride {
                return realtimeEventTransportOverride(data)
            }
            #if canImport(WebRTC)
            guard let dataChannel, dataChannel.readyState == .open else {
                Self.logger.warning("Realtime event transport unavailable for event: \(String(describing: payload["type"]))")
                return false
            }
            return dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
            #else
            Self.logger.warning("Realtime event transport unavailable in non-WebRTC build for event: \(String(describing: payload["type"]))")
            return false
            #endif
        } catch {
            Self.logger.warning("Failed to encode realtime event \(String(describing: payload["type"])): \(error.localizedDescription)")
            return false
        }
    }
}

#if canImport(WebRTC)
private final class RealtimePeerDelegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    weak var owner: LiveVoiceSessionService?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else { return }
            if owner.isEndingSession {
                return
            }
            switch state {
            case .open:
                owner.connectionState = .connected
                owner.voiceState = .listening
                owner.statusMessage = "Listening"
            case .closed, .closing:
                owner.connectionState = .failed
                owner.voiceState = .disconnected
                owner.statusMessage = "Connection lost."
            default:
                break
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let text = String(data: buffer.data, encoding: .utf8),
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        Task { @MainActor in
            owner?.handleDataChannelEvent(payload)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCPeerConnectionState) {
        Task { @MainActor in
            guard let owner else { return }
            if owner.isEndingSession {
                return
            }
            switch stateChanged {
            case .connected:
                if owner.latencyMetrics.realtimeConnectedAt == nil {
                    owner.latencyMetrics.realtimeConnectedAt = .now
                }
                owner.connectionState = .connected
                owner.voiceState = .listening
                owner.statusMessage = "Listening"
            case .failed, .disconnected, .closed:
                owner.connectionState = .failed
                owner.voiceState = .disconnected
                owner.statusMessage = "Talk connection lost."
            default:
                break
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
}

private extension RTCPeerConnection {
    func createOfferAsync() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            self.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), completionHandler: { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: RelayAPIClient.ClientError.requestFailed("Failed to create WebRTC offer."))
                }
            })
        }
    }

    func setLocalDescriptionAsync(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setRemoteDescriptionAsync(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif
