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

/// Hands-free wake word ("hey hermes" / "oi hermes") + voice commands for the chat.
///
/// Built on the same on-device iOS 26 Speech stack as `LiveSpeechService`
/// (dictation) — `DictationTranscriber` + `SpeechAnalyzer` — but the analyzer stays
/// armed instead of stopping at the first final result:
///
/// 1. every partial transcript is scanned for the wake phrase;
/// 2. once heard, whatever follows becomes the command;
/// 3. after a short silence the command is handed to `onCommand`, which the caller
///    sends through the normal chat pipeline;
/// 4. the assistant's reply is spoken with the system voice, then listening resumes.
///
/// The microphone is released while Hermes thinks/speaks, so the app never
/// transcribes its own voice. The `audio` background mode declared in the project
/// keeps the listener alive while the app is not frontmost.
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

    /// Silence after the last recognized word that closes the command.
    private static let silenceToFinishCommand: TimeInterval = 1.6
    /// How long to wait for a command to *start* after the wake phrase.
    private static let silenceBeforeCommand: TimeInterval = 5
    /// Hard cap for a single spoken command.
    private static let maxCommandSeconds: TimeInterval = 20
    /// Grace period after the reply before the mic goes live again.
    private static let cooldownAfterCommand: TimeInterval = 1.2
    /// Ignore transcripts for this long after resuming (own-speech tail).
    private static let resumeSuppression: TimeInterval = 1.0
    /// Give up waiting for the assistant reply and listen again.
    private static let replyTimeout: TimeInterval = 90
    /// Shortest accepted command.
    private static let minimumCommandLength = 2
    /// Retry delay after a listener failure.
    private static let failureRetryDelay: TimeInterval = 3

    /// Words that may precede "hermes" to form the wake phrase.
    nonisolated private static let wakePrefixes: Set<String> = ["hey", "hei", "oi", "ei", "ola", "ok", "okay", "opa"]

    // MARK: - Observable state

    private(set) var phase: Phase = .off
    private(set) var lastCommand: String?
    private(set) var lastError: String?

    var isEnabled: Bool { phase != .off }

    /// Called with the spoken command (already stripped of the wake phrase).
    /// Async so the caller can push it through the chat pipeline before the
    /// service continues (the reply is spoken back later).
    var onCommand: (@MainActor (String) async -> Void)?

    // MARK: - Internals

    private let listener = WakeListener()
    private let announcer = SpeechAnnouncer()
    private var eventTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var replyTimeoutTask: Task<Void, Never>?
    private var isRunning = false

    private var isSuspended = false
    private var capturing = false
    private var triggerSegment = -1
    private var committedCommand = ""
    private var currentSegmentText = ""
    private var captureStartedAt = Date.distantPast
    private var lastTextAt = Date.distantPast
    private var suppressUntil = Date.distantPast

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            await stop()
        }
    }

    func start() async {
        guard !isRunning else { return }
        do {
            try await Self.requestPermissions()
        } catch {
            lastError = error.localizedDescription
            phase = .off
            Self.logger.error("wake word permissions refused: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            let stream = try await listener.start()
            isRunning = true
            lastError = nil
            phase = .listening
            consume(stream)
            startSilenceWatch()
            Self.logger.info("wake word listener armed")
        } catch {
            isRunning = false
            phase = .off
            lastError = error.localizedDescription
            Self.logger.error("wake word start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        isRunning = false
        resetCapture()
        eventTask?.cancel()
        eventTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        announcer.stop()
        await listener.stop()
        phase = .off
        Self.logger.info("wake word listener stopped")
    }

    /// Keeps the listener healthy when the app comes back to the foreground.
    func handleAppBecameActive() async {
        guard isRunning, !isSuspended else { return }
        await listener.restartIfNeeded()
        if phase == .off { phase = .listening }
    }

    /// Hands the microphone over to another capture path (Talk mode, chat
    /// dictation). The listener stays enabled but releases the mic.
    func suspendForExternalCapture() async {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        resetCapture()
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        await listener.pause()
        phase = .off
        Self.logger.info("wake word suspended for external capture")
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
    }

    // MARK: - Reply handling

    /// Called with the assistant's final message content for a streamed reply.
    func handleAssistantReply(_ text: String) {
        guard phase == .thinking else { return }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        phase = .speaking
        Task { [weak self] in
            guard let self else { return }
            await self.announcer.speak(text)
            await self.resumeListening(after: Self.cooldownAfterCommand)
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
            guard isRunning, !isSuspended else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.failureRetryDelay))
                guard let self, self.isRunning, !self.isSuspended else { return }
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
            guard let remainder = Self.commandAfterTrigger(in: trimmed) else { return }
            capturing = true
            triggerSegment = segment
            committedCommand = ""
            currentSegmentText = remainder
            captureStartedAt = Date()
            lastTextAt = Date()
            phase = .capturing
            Self.logger.info("wake phrase detected")
            return
        }

        if segment == triggerSegment {
            currentSegmentText = Self.commandAfterTrigger(in: trimmed) ?? ""
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
        // Right after the wake phrase the user may pause ("oi hermes… <pausa> …comando"),
        // so an empty command gets a longer grace period than one already in progress.
        let pending = Self.join(committedCommand, currentSegmentText)
        let idleLimit = pending.isEmpty ? Self.silenceBeforeCommand : Self.silenceToFinishCommand
        if idle >= idleLimit || elapsed >= Self.maxCommandSeconds {
            await finalizeCommand()
        }
    }

    private func finalizeCommand() async {
        let command = Self.join(committedCommand, currentSegmentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        resetCapture()

        guard command.count >= Self.minimumCommandLength else {
            // False trigger: keep listening.
            phase = .listening
            return
        }

        lastCommand = command
        phase = .thinking
        // Release the mic before the agent works (and before the reply is spoken).
        await listener.pause()
        Self.logger.info("wake command dispatched (\(command.count, privacy: .public) chars)")
        await onCommand?(command)
        armReplyTimeout()
    }

    private func armReplyTimeout() {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.replyTimeout))
            guard let self else { return }
            guard self.phase == .thinking else { return }
            Self.logger.error("no assistant reply for wake command — listening again")
            await self.resumeListening(after: 0)
        }
    }

    private func resumeListening(after delay: TimeInterval) async {
        guard isRunning else { return }
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        guard isRunning else { return }
        await listener.resume()
        suppressUntil = Date().addingTimeInterval(Self.resumeSuppression)
        phase = .listening
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

    /// Returns the command text that follows the wake phrase, or `nil` when the
    /// transcript is not addressed to the wake word.
    ///
    /// Matches "hermes" (case/accent-insensitive) when it either starts the
    /// utterance or is preceded by a wake prefix ("hey", "oi", "ei", …). A bare
    /// mention inside a sentence ("o hermes respondeu…") never triggers.
    nonisolated static func commandAfterTrigger(in text: String) -> String? {
        guard let range = text.range(of: "hermes", options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let before = String(text[text.startIndex..<range.lowerBound])
        let after = String(text[range.upperBound...])
        let wordsBefore = before
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let hasPrefix = wordsBefore.last.map { word in
            wakePrefixes.contains(fold(word))
        } ?? false
        let startsUtterance = wordsBefore.isEmpty
        guard hasPrefix || startsUtterance else { return nil }

        return trimLeadingPunctuation(after)
    }

    private nonisolated static func fold(_ word: String) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: .current)
    }

    private nonisolated static func trimLeadingPunctuation(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, !first.isLetter, !first.isNumber {
            slice = slice.dropFirst()
        }
        return String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func join(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}

// MARK: - Spoken replies

/// Speaks the assistant's reply with the system voice.
///
/// `AVSpeechSynthesizer` has no async completion, so playback is tracked by
/// polling `isSpeaking` (delegate callbacks would add an isolation headache for
/// no benefit here).
@MainActor
final class SpeechAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private static let maxSpeechSeconds: TimeInterval = 600

    func speak(_ text: String) async {
        let spoken = Self.speechFriendly(text)
        guard !spoken.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.preferredVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)

        // Give the synthesizer a moment to start before trusting `isSpeaking`.
        try? await Task.sleep(for: .milliseconds(400))
        var waited: TimeInterval = 0
        while synthesizer.isSpeaking, waited < Self.maxSpeechSeconds {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let portuguese = AVSpeechSynthesisVoice(language: "pt-BR") {
            return portuguese
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice(language: language)
    }

    /// Strips markdown/MEDIA noise so the reply reads well out loud.
    nonisolated static func speechFriendly(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " (bloco de código omitido) ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: "(?m)^\\s*#{1,6}\\s*", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "MEDIA:\\s*\\S+", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "[*_~>#|]", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > 1200 {
            output = String(output.prefix(1200)) + "…"
        }
        return output
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
    private var outputContinuation: AsyncStream<Event>.Continuation?
    private var isSegmentRunning = false
    private var segmentStartedAt = Date.distantPast
    private var isStopped = true
    private var isPaused = false
    private var segmentCounter = 0
    private var tapInstalled = false

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

        let formatsMatch =
            inputFormat.sampleRate == resolvedAnalyzerFormat.sampleRate &&
            inputFormat.channelCount == resolvedAnalyzerFormat.channelCount &&
            inputFormat.commonFormat == resolvedAnalyzerFormat.commonFormat &&
            inputFormat.isInterleaved == resolvedAnalyzerFormat.isInterleaved
        let converter = formatsMatch ? nil : AVAudioConverter(from: inputFormat, to: resolvedAnalyzerFormat)
        converter?.primeMethod = .none
        audioConverter = converter

        let box = inputBox
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converted = Self.convertBuffer(buffer, using: converter, outputFormat: resolvedAnalyzerFormat) else {
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
    func restartIfNeeded() async {
        guard !isStopped, !isPaused, !isSegmentRunning else { return }
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
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }

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

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        outputContinuation?.finish()
        outputContinuation = nil
    }

    // MARK: - Segments

    private func startSegment() async throws {
        guard !isStopped, !isPaused else { return }
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
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func emit(_ event: Event) {
        outputContinuation?.yield(event)
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
