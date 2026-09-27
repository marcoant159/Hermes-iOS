import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

enum WakeWordError: LocalizedError {
    case speechDenied
    case microphoneDenied
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .speechDenied:
            "Speech recognition permission is required for the wake word."
        case .microphoneDenied:
            "Microphone access is required for the wake word."
        case .speechUnavailable:
            "On-device speech recognition is unavailable for this language."
        }
    }
}

/// Hands-free wake word ("oi hermes") that opens the GPT Live voice session.
///
/// Built on the same on-device iOS 26 Speech stack as `LiveSpeechService`
/// (dictation) — `DictationTranscriber` + `SpeechAnalyzer` — but the analyzer stays
/// armed instead of stopping at the first final result:
///
/// 1. every partial transcript is scanned for the wake phrase ("oi hermes");
/// 2. once heard, a short confirmation beep plays;
/// 3. whatever follows in the same utterance is captured as the command;
/// 4. after a short silence the microphone is handed over (`onWakeActivation`),
///    which starts a GPT Live voice session; the same-utterance command (if any)
///    is injected into that session by the caller.
///
/// The `audio` background mode declared in the project keeps the listener alive
/// while the app is not frontmost, and the session can start without any UI.
@MainActor
@Observable
final class LiveWakeWordService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "br.com.marcoant.hermes",
        category: "WakeWord"
    )

    enum Phase: String, Equatable, Sendable {
        case off
        case listening
        case capturing
        case thinking
        case speaking

        var label: String {
            switch self {
            case .off: "Off"
            case .listening: "Listening"
            case .capturing: "Recording command"
            case .thinking: "Waiting for Hermes"
            case .speaking: "Speaking"
            }
        }
    }

    // MARK: - Tuning

    /// Silence after the last recognized word that closes the wake activation.
    /// A bare "oi hermes" also opens the session after this window.
    private static let silenceToFinishCommand: TimeInterval = 1.6
    /// Short probe used right after a bare "oi hermes" with no command yet: if no
    /// further speech arrives, open the session immediately instead of waiting the
    /// full command window. This is what makes the wake activation feel instant;
    /// anything the user says next is picked up by the GPT Live session itself.
    private static let bareWakeSilence: TimeInterval = 0.6
    /// Hard cap for a single spoken command.
    private static let maxCommandSeconds: TimeInterval = 20
    /// Ignore transcripts for this long after resuming (own-speech tail).
    private static let resumeSuppression: TimeInterval = 1.0
    /// Shortest accepted same-utterance command.
    private static let minimumCommandLength = 2
    /// Retry delay after a listener failure.
    private static let failureRetryDelay: TimeInterval = 3
    /// Short system sound played to confirm the wake phrase.
    private static let activationSoundID: SystemSoundID = 1113

    /// The default wake phrase is "oi hermes". The accepted phrase (and its
    /// transcription variants) is configurable in Settings → Hands-Free and
    /// pushed via ``apply(settings:)``; it defaults to the built-in phrase so the
    /// listener works before any settings are applied.
    private var wakePhrase = WakePhrase.defaultPhrase

    // MARK: - Observable state

    private(set) var phase: Phase = .off
    private(set) var lastCommand: String?
    private(set) var lastError: String?

    var isEnabled: Bool { phase != .off }

    /// The activation phrase currently being listened for (for the Settings UI).
    var currentPhraseText: String { wakePhrase.displayText }

    /// `true` while listening is paused so another capture path (Talk mode,
    /// chat dictation) can own the microphone. `phase` reads `.off` in this
    /// state, so the UI uses this to avoid showing "Starting…".
    var isSuspendedForExternalCapture: Bool { isSuspended }

    /// `true` while a CarPlay scene is connected. Apple's voice-based
    /// conversational category forbids activating the app by its wake word in
    /// the car, so the listener stays disarmed for the whole connection. The
    /// Settings screen shows a specific message for this state.
    var isSuspendedForCarPlay: Bool { isCarPlayConnected }

    /// Called once the wake phrase (and any same-utterance command) is ready.
    /// The caller starts a GPT Live voice session and injects `command` when it
    /// is non-nil. Async so the microphone is handed over before the callback
    /// runs, and so the caller can complete the session bootstrap in order.
    var onWakeActivation: (@MainActor (String?) async -> Void)?

    /// Called for every listener lifecycle/diagnostic event (armed, stopped,
    /// suspended, resumed, phrase detected, session opened/failed…). The caller
    /// forwards these to the relay so the operator can see on-device behaviour.
    var onWakeEvent: (@MainActor (String) async -> Void)?

    // MARK: - Internals

    private let listener = WakeListener()
    private var eventTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var isRunning = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    private var isSuspended = false
    private(set) var isCarPlayConnected = false
    private var capturing = false
    private var triggerSegment = -1
    private var committedCommand = ""
    private var currentSegmentText = ""
    private var captureStartedAt = Date.distantPast
    private var lastTextAt = Date.distantPast
    private var suppressUntil = Date.distantPast

    init() {
        let center = NotificationCenter.default
        // The system can interrupt (call/Siri) or reset the audio stack while we
        // are recording in the background. Re-arm the listener so "oi hermes"
        // keeps working without requiring the app to come back to foreground.
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let rawValue,
                      let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
                await self.handleAudioInterruption(type)
            }
        }
        mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.recoverAudioAfterReset()
            }
        }
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            await stop()
        }
    }

    /// Pushes the user's chosen activation phrase. Safe to call while listening:
    /// only the matcher input changes, the audio stack is untouched. Does nothing
    /// when the phrase is unchanged, so it can be called on every settings write.
    func apply(settings: UserSettings) {
        let phrase = WakePhrase(
            preset: settings.wakePhrasePreset,
            customText: settings.wakePhraseCustomText
        )
        guard phrase != wakePhrase else { return }
        wakePhrase = phrase
        emitWakeEvent("wake phrase set to \(phrase.displayText)")
    }

    func start() async {
        // Disarmed for the whole CarPlay connection (Apple forbids wake-word
        // activation of a voice-based conversational app in the car). Never
        // arm or re-arm until `endCarPlaySuppression()` runs on disconnect.
        if isCarPlayConnected {
            emitWakeEvent("listener start ignored while CarPlay is connected")
            return
        }

        // Already armed: recover instead of bailing out. This is the path taken
        // when the listener was suspended for an external capture and the app
        // re-arms it on foreground; returning at the old `guard !isRunning`
        // left `isSuspended == true` forever and the listener stayed mute.
        if isRunning {
            if isSuspended {
                await resumeAfterExternalCapture()
            } else {
                await listener.recoverIfNeeded()
                if phase == .off { phase = .listening }
            }
            return
        }

        isSuspended = false
        do {
            try await Self.requestPermissions()
        } catch {
            lastError = error.localizedDescription
            phase = .off
            Self.logger.error("wake word permissions refused: \(error.localizedDescription, privacy: .public)")
            emitWakeEvent("listener permission denied: \(error.localizedDescription)")
            return
        }

        // The listener is enabled from the settings toggle; make sure the phrase
        // reflects the user's current choice before arming.
        apply(settings: AppContainer.sharedDefault().settingsStore.settings)

        do {
            let stream = try await listener.start()
            isRunning = true
            lastError = nil
            phase = .listening
            consume(stream)
            startSilenceWatch()
            Self.logger.info("wake word listener armed")
            emitWakeEvent("listener armed")
        } catch {
            isRunning = false
            phase = .off
            lastError = error.localizedDescription
            Self.logger.error("wake word start failed: \(error.localizedDescription, privacy: .public)")
            emitWakeEvent("listener start failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        isRunning = false
        isSuspended = false
        resetCapture()
        eventTask?.cancel()
        eventTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        await listener.stop()
        phase = .off
        Self.logger.info("wake word listener stopped")
        emitWakeEvent("listener stopped")
    }

    /// Re-arms the listener when the app returns to the foreground or when an
    /// external capture finishes. Safe to call repeatedly. Does not disturb an
    /// in-flight wake activation (capturing).
    func ensureListening() async {
        // A CarPlay connection keeps the microphone disarmed even when the app
        // comes to the foreground or a voice session ends.
        guard !isCarPlayConnected else { return }
        guard !capturing else { return }
        if !isRunning {
            await start()
        } else if isSuspended {
            await resumeAfterExternalCapture()
        } else {
            await listener.recoverIfNeeded()
            if phase == .off { phase = .listening }
        }
    }

    /// Keeps the listener healthy when the app comes back to the foreground.
    func handleAppBecameActive() async {
        await ensureListening()
    }

    /// Hands the microphone over to another capture path (Talk mode, chat
    /// dictation). The listener stays enabled but releases the mic.
    func suspendForExternalCapture() async {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        resetCapture()
        await listener.pause()
        phase = .off
        Self.logger.info("wake word suspended for external capture")
        emitWakeEvent("listener suspended for external capture")
    }

    /// Re-arms after the other capture path is done.
    func resumeAfterExternalCapture() async {
        guard isRunning, isSuspended else { return }
        isSuspended = false
        // Let the other session finish tearing down before taking the mic back.
        try? await Task.sleep(for: .milliseconds(800))
        guard isRunning, !isSuspended else { return }
        await listener.resume()
        suppressUntil = Date().addingTimeInterval(Self.resumeSuppression)
        phase = .listening
        if let lastError {
            emitWakeEvent("listener resumed after error: \(lastError)")
        } else {
            emitWakeEvent("listener resumed")
        }
    }

    // MARK: - CarPlay arbitration

    /// Disarms the listener for the whole CarPlay connection and releases the
    /// microphone. Apple's voice-based conversational rules require the app to
    /// be opened manually on the car screen and forbid activating it by wake
    /// word, so nothing re-arms the listener until the car disconnects.
    ///
    /// The user's saved preference is never changed; only the runtime capture is
    /// suppressed. A voice session already using the microphone keeps it.
    func beginCarPlaySuppression() async {
        guard !isCarPlayConnected else { return }
        isCarPlayConnected = true
        if isRunning, !isSuspended {
            await suspendForExternalCapture()
        } else {
            phase = .off
        }
        emitWakeEvent("listener suppressed while CarPlay is connected")
    }

    /// Clears the CarPlay suppression. Does not re-arm by itself: the caller
    /// re-arms through `AppContainer.startWakeWordIfEnabled()` so a live voice
    /// session (or a user-disabled preference) is still respected.
    func endCarPlaySuppression() async {
        guard isCarPlayConnected else { return }
        isCarPlayConnected = false
        emitWakeEvent("listener suppression cleared after CarPlay disconnected")
    }

    // MARK: - Audio recovery

    private func handleAudioInterruption(_ type: AVAudioSession.InterruptionType) async {
        switch type {
        case .began:
            emitWakeEvent("listener interrupted by system")
        case .ended:
            guard isRunning, !isSuspended, !isCarPlayConnected else { return }
            await listener.recoverIfNeeded()
            if phase == .off { phase = .listening }
            emitWakeEvent("listener re-armed after interruption")
        @unknown default:
            break
        }
    }

    private func recoverAudioAfterReset() async {
        guard isRunning, !isSuspended, !isCarPlayConnected, !capturing else { return }
        await listener.forceRestart()
        if phase == .off { phase = .listening }
        emitWakeEvent("listener re-armed after media reset")
    }

    /// Logs locally and forwards to the relay for remote diagnosis.
    private func emitWakeEvent(_ event: String) {
        Self.logger.info("wake event: \(event, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self, let onWakeEvent = self.onWakeEvent else { return }
            await onWakeEvent(event)
        }
    }

    // MARK: - Listener plumbing

    private func consume(_ stream: AsyncStream<WakeListener.Event>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                await MainActor.run {
                    self.handle(event)
                }
            }
        }
    }

    private func handle(_ event: WakeListener.Event) {
        switch event {
        case .text(let text, let isFinal, let segment):
            handleTranscript(text, isFinal: isFinal, segment: segment)
        case .failed(let message):
            lastError = message
            Self.logger.error("wake listener failed: \(message, privacy: .public)")
            emitWakeEvent("listener failed: \(message)")
            guard isRunning, !isSuspended, !isCarPlayConnected else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.failureRetryDelay))
                guard let self, self.isRunning, !self.isSuspended, !self.isCarPlayConnected else { return }
                await self.listener.restartIfNeeded()
                if self.phase == .off {
                    self.phase = .listening
                }
            }
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool, segment: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Date() >= suppressUntil else { return }

        if !capturing {
            guard let remainder = wakePhrase.match(in: trimmed)?.remainder else { return }
            capturing = true
            triggerSegment = segment
            committedCommand = ""
            currentSegmentText = remainder
            captureStartedAt = Date()
            lastTextAt = Date()
            phase = .capturing
            Self.playActivationSound()
            Self.logger.info("wake phrase detected")
            emitWakeEvent("wake phrase detected")
            return
        }

        if segment == triggerSegment {
            // Partial (volatile) re-transcriptions of the trigger segment keep
            // rewriting the whole utterance; re-extract the command each time so
            // no spoken words are lost between partials.
            currentSegmentText = wakePhrase.match(in: trimmed)?.remainder ?? ""
        } else {
            currentSegmentText = trimmed
        }
        lastTextAt = Date()

        if isFinal {
            committedCommand = Self.join(committedCommand, currentSegmentText)
            currentSegmentText = ""
            triggerSegment = -1
        }
    }

    private func startSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.tickSilence()
            }
        }
    }

    private func tickSilence() async {
        guard isRunning, capturing else { return }
        let idle = Date().timeIntervalSince(lastTextAt)
        let elapsed = Date().timeIntervalSince(captureStartedAt)
        // A bare "oi hermes" opens the session as soon as the short probe elapses;
        // a same-utterance command keeps the longer window so the user can finish
        // speaking before the GPT Live session takes over the microphone.
        let threshold = hasCapturedCommand ? Self.silenceToFinishCommand : Self.bareWakeSilence
        if idle >= threshold || elapsed >= Self.maxCommandSeconds {
            await finalizeCommand()
        }
    }

    /// `true` once any text after the wake phrase has been recognized for the
    /// current activation (either already committed or still partial).
    private var hasCapturedCommand: Bool {
        !Self.join(committedCommand, currentSegmentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func finalizeCommand() async {
        let command = Self.join(committedCommand, currentSegmentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        resetCapture()

        // A bare "oi hermes" is a valid activation (case a): the GPT Live
        // session opens and the user speaks the question there.
        let payload = command.count >= Self.minimumCommandLength ? command : nil
        lastCommand = payload
        phase = .thinking
        // Release the mic before the external voice session takes over.
        await suspendForExternalCapture()
        let commandState = payload == nil ? "none" : "present"
        Self.logger.info("wake activation dispatched (command: \(commandState, privacy: .public))")
        emitWakeEvent("wake activation dispatched (command: \(commandState))")
        await onWakeActivation?(payload)
    }

    private static func playActivationSound() {
        AudioServicesPlaySystemSound(activationSoundID)
    }

    private func resetCapture() {
        capturing = false
        triggerSegment = -1
        committedCommand = ""
        currentSegmentText = ""
    }

    // MARK: - Permissions

    private static func requestPermissions() async throws {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            speechStatus = SFSpeechRecognizer.authorizationStatus()
        }
        guard speechStatus == .authorized else { throw WakeWordError.speechDenied }

        let microphoneStatus = AVAudioApplication.shared.recordPermission
        if microphoneStatus == .undetermined {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw WakeWordError.microphoneDenied
            }
        } else if microphoneStatus != .granted {
            throw WakeWordError.microphoneDenied
        }
    }

    // MARK: - Trigger matching

    /// Returns the command text that follows the configured wake phrase, or `nil`
    /// when the transcript is not addressed to the wake word.
    ///
    /// Matching (normalization, transcription variants and the small edit-distance
    /// tolerance) lives in ``WakePhrase`` so it can be unit-tested in isolation.
    func commandAfterTrigger(in text: String) -> String? {
        wakePhrase.match(in: text)?.remainder
    }

    private nonisolated static func join(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}

// MARK: - On-device listener

/// Continuous on-device dictation stream.
///
/// Mirrors `DictationController` from `LiveSpeechService`, but instead of stopping
/// at the first final result it restarts the analyzer so the wake word stays armed.
/// Segments are numbered so the service can tell a cumulative partial (same
/// segment) from fresh speech (new segment).
private actor WakeListener {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "br.com.marcoant.hermes",
        category: "WakeListener"
    )

    enum Event: Sendable {
        case text(String, isFinal: Bool, segment: Int)
        case failed(String)
    }

    /// Mutable continuation shared with the audio tap (which runs off-actor).
    private final class InputBox: @unchecked Sendable {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
    }

    private let audioEngine = AVAudioEngine()
    private let inputBox = InputBox()

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var reservedLocale: Locale?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var segmentTeardownTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<Event>.Continuation?
    private var isSegmentRunning = false
    private var isSegmentTearingDown = false
    private var segmentStartedAt = Date.distantPast
    private var isStopped = true
    private var isPaused = false
    private var segmentCounter = 0
    private var tapInstalled = false
    private var sessionConfigured = false

    func start() async throws -> AsyncStream<Event> {
        stop()

        // Use the device's preferred language. Locale.current can fall back to
        // this English-only app's localization instead of the user's language.
        let preferredLocale = Locale(
            identifier: Locale.preferredLanguages.first ?? Locale.current.identifier
        )
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: preferredLocale
        ) else {
            throw WakeWordError.speechUnavailable
        }

        isStopped = false
        isPaused = false
        segmentCounter = 0

        let outputStream = AsyncStream<Event> { continuation in
            self.outputContinuation = continuation
        }

        if try await AssetInventory.reserve(locale: locale) {
            reservedLocale = locale
            Self.logger.info("Reserved wake locale \(locale.identifier, privacy: .public)")
        }

        try activateSession()

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let resolvedAnalyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [DictationTranscriber(locale: locale, preset: .progressiveShortDictation)],
            considering: inputFormat
        ) ?? inputFormat
        analyzerFormat = resolvedAnalyzerFormat

        updateConverter(for: inputFormat)

        // Capture the converter in the tap closure so restarts reuse the exact
        // same instance (replacing `audioConverter` alone would leave the tap
        // converting with a stale converter).
        let captureConverter = audioConverter
        let box = inputBox
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converted = Self.convertBuffer(buffer, using: captureConverter, outputFormat: resolvedAnalyzerFormat) else {
                return
            }
            box.continuation?.yield(AnalyzerInput(buffer: converted))
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        try await startSegment()

        return outputStream
    }

    /// Releases the microphone without tearing the listener down.
    func pause() async {
        guard !isStopped else { return }
        isPaused = true
        await endSegment()
        audioEngine.stop()
        deactivateSession()
    }

    /// Re-arms capture after `pause()`.
    func resume() async {
        guard !isStopped, isPaused else { return }
        isPaused = false
        do {
            try activateSession()
            audioEngine.prepare()
            try audioEngine.start()
            try await startSegment()
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    /// Re-arms the analyzer if the segment died (app resumed, audio interruption…).
    /// A no-op while a previous segment is still tearing down: otherwise two
    /// `SpeechAnalyzer`/`DictationTranscriber` pairs would coexist and the speech
    /// framework reports "Maximum number of recognizers reached".
    func restartIfNeeded() async {
        guard !isStopped, !isPaused, !isSegmentRunning, !isSegmentTearingDown else { return }
        do {
            if !audioEngine.isRunning {
                try activateSession()
                audioEngine.prepare()
                try audioEngine.start()
            }
            try await startSegment()
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    /// Re-arms capture after the audio stack was taken over by another subsystem
    /// (a voice session calling `setActive(false)`, an interruption, a media
    /// reset). Unlike `restartIfNeeded`, it does not bail out when a stale
    /// segment is still marked as running or when the listener is paused.
    func recoverIfNeeded() async {
        guard !isStopped else { return }
        if isPaused {
            await resume()
            return
        }
        if audioEngine.isRunning, isSegmentRunning { return }
        // Let any in-flight teardown finish before creating a new analyzer, so we
        // never hold two transcribers at once.
        while isSegmentTearingDown {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await forceRestart()
    }

    /// Tears the current segment down and brings the engine + analyzer back up.
    func forceRestart() async {
        guard !isStopped, !isPaused else { return }
        while isSegmentTearingDown {
            try? await Task.sleep(for: .milliseconds(50))
        }
        restartTask?.cancel()
        restartTask = nil
        await endSegment()
        restartTask?.cancel()
        restartTask = nil
        do {
            if !audioEngine.isRunning {
                try activateSession()
                audioEngine.prepare()
                try audioEngine.start()
            }
            try await startSegment()
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    func stop() {
        isStopped = true
        isPaused = false
        isSegmentRunning = false
        restartTask?.cancel()
        restartTask = nil
        segmentTeardownTask?.cancel()
        segmentTeardownTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputBox.continuation?.finish()
        inputBox.continuation = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil
        if let analyzer {
            // Await the teardown instead of detaching it in an unstructured Task:
            // a short-lived listener stop+start (settings toggle) used to race the
            // previous analyzer's `cancelAndFinishNow` and leak recognizers.
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        // Do not let a stale teardown from the old segment block the next start.
        isSegmentTearingDown = false

        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if let locale = reservedLocale {
            reservedLocale = nil
            Task {
                _ = await AssetInventory.release(reservedLocale: locale)
            }
        }

        deactivateSession()

        outputContinuation?.finish()
        outputContinuation = nil
    }

    // MARK: - Segments

    private func startSegment() async throws {
        guard !isStopped, !isPaused else { return }
        guard audioEngine.isRunning else {
            // Starting an analyzer without a live engine leaves a transcriber
            // alive until the next attempt, which is one of the ways the speech
            // framework hits "Maximum number of recognizers reached".
            throw WakeWordError.speechUnavailable
        }
        let preferredLocale = Locale(
            identifier: Locale.preferredLanguages.first ?? Locale.current.identifier
        )
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: preferredLocale
        ),
              let analyzerFormat else {
            throw WakeWordError.speechUnavailable
        }

        segmentCounter += 1
        let segment = segmentCounter
        isSegmentRunning = true
        segmentStartedAt = Date()

        // The input node format can change after an interruption/route change
        // (e.g. switching microphones), which used to leave the tap feeding a
        // converter for the wrong format and produce AVFAudio errors.
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, inputNodeIsUsable(inputFormat) else {
            throw WakeWordError.speechUnavailable
        }
        updateConverter(for: inputFormat)

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat) { _ in }
        self.analyzer = analyzer

        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            self.inputBox.continuation = continuation
        }

        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                await self?.handleSegmentFailure(error)
            }
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await self?.emit(.text(text, isFinal: true, segment: segment))
                        await self?.endSegment()
                        break
                    } else {
                        await self?.emit(.text(text, isFinal: false, segment: segment))
                    }
                }
            } catch {
                await self?.handleSegmentFailure(error)
            }
        }
    }

    private func endSegment() async {
        // Serialize teardowns: two overlapping `cancelAndFinishNow` calls on the
        // same analyzer family are what produced the AVFAudio -10868 /
        // "Maximum number of recognizers reached" storms while re-arming.
        while isSegmentTearingDown {
            try? await Task.sleep(for: .milliseconds(50))
        }
        isSegmentTearingDown = true
        defer { isSegmentTearingDown = false }

        isSegmentRunning = false
        analyzerTask?.cancel()
        analyzerTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputBox.continuation?.finish()
        inputBox.continuation = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }

        guard !isStopped, !isPaused else { return }
        // Don't hammer the analyzer when a segment finalizes instantly (silence/noise).
        let ranFor = Date().timeIntervalSince(segmentStartedAt)
        let restartDelay = ranFor < 1.0 ? 1000 : 250
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(restartDelay))
            await self?.restartIfNeeded()
        }
    }

    private func handleSegmentFailure(_ error: Error) async {
        Self.logger.error("wake segment failed: \(error.localizedDescription, privacy: .public)")
        emit(.failed(error.localizedDescription))
        await endSegment()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.duckOthers, .defaultToSpeaker]
        // `.playAndRecord` (instead of `.record`) keeps the session eligible to
        // record while the app is in the background and lets the wake
        // confirmation beep play. `.defaultToSpeaker` avoids routing it to the
        // earpiece when no headset is connected.
        //
        // Reconfiguring the category on every re-arm while the session is already
        // active is what triggered the AVFAudio OSStatus 560557684 /
        // 2003329396 errors on segment restarts: only set it when the current
        // configuration differs.
        if !sessionConfigured || session.category != .playAndRecord || session.mode != .measurement {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
            sessionConfigured = true
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Releases the shared audio session. Keeps `sessionConfigured` set so the
    /// next `activateSession()` does not re-apply the (unchanged) category.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func emit(_ event: Event) {
        outputContinuation?.yield(event)
    }

    /// Builds the input→analyzer converter for `inputFormat`, or clears it when
    /// the formats already match. Rebuilt on every (re)start so a route change
    /// (different microphone) cannot keep a converter bound to a dead format.
    private func updateConverter(for inputFormat: AVAudioFormat) {
        guard let analyzerFormat,
              inputFormat.sampleRate > 0,
              analyzerFormat.sampleRate > 0 else {
            audioConverter = nil
            return
        }
        let formatsMatch =
            inputFormat.sampleRate == analyzerFormat.sampleRate &&
            inputFormat.channelCount == analyzerFormat.channelCount &&
            inputFormat.commonFormat == analyzerFormat.commonFormat &&
            inputFormat.isInterleaved == analyzerFormat.isInterleaved
        if formatsMatch {
            audioConverter = nil
        } else {
            let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            converter?.primeMethod = .none
            audioConverter = converter
        }
    }

    /// Guards against an input node whose format collapsed after a route change.
    private func inputNodeIsUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate >= 8000
    }

    nonisolated private static func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        final class ConversionState: @unchecked Sendable {
            var didProvideInput = false
        }

        guard let converter else { return inputBuffer }

        let frameRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = max(
            inputBuffer.frameLength,
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * frameRatio)) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        let state = ConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            } else {
                state.didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
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
}
