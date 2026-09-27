import CarPlay
import UIKit

/// Bridges `TalkStore` voice state to the CarPlay `CPVoiceControlTemplate`.
///
/// Hermes is a "voice-based conversational app": the template is the primary
/// UI, it shows the current voice state, and (iOS 26.4+) offers action buttons
/// to start/end the conversation. Session logic is never duplicated here — it
/// goes straight to `TalkStore` / `AppContainer`, the same stores the iPhone UI
/// and the wake word use.
@MainActor
final class CarPlayVoiceManager {
    private enum VoiceControlStateID {
        static let ready = "ready"
        static let connecting = "connecting"
        static let listening = "listening"
        static let thinking = "thinking"
        static let consulting = "consulting"
        static let speaking = "speaking"
        static let unavailable = "unavailable"
    }

    private enum SessionAction {
        case start
        case end
    }

    private let interfaceController: CPInterfaceController
    private var voiceTemplate: CPVoiceControlTemplate?
    private var observationTask: Task<Void, Never>?
    private var lastSyncedStateID: String?

    /// `true` only when this screen opened the live session. It decides whether
    /// disconnecting from the car should close the session: a session the user
    /// started on the iPhone keeps running.
    private var didStartSession = false

    private var container: AppContainer { AppContainer.sharedDefault() }
    private var talkStore: TalkStore { container.talkStore }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    // MARK: - Lifecycle

    func configure() async {
        // Resolve readiness (paired? relay reachable?) before drawing, so the
        // first screen already knows whether the conversation can start.
        await talkStore.refreshReadiness()

        let template = buildVoiceControlTemplate()
        voiceTemplate = template
        let initialStateID = currentStateIdentifier()
        lastSyncedStateID = initialStateID

        interfaceController.setRootTemplate(template, animated: false) { _, _ in
            template.activateVoiceControlState(withIdentifier: initialStateID)
        }

        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.syncState()
            }
        }
    }

    /// Called when the vehicle disconnects. Closes the session this screen
    /// opened (never a session that was already running on the iPhone) and
    /// releases the CarPlay references.
    func tearDown() async {
        observationTask?.cancel()
        observationTask = nil
        voiceTemplate = nil
        lastSyncedStateID = nil

        if didStartSession {
            didStartSession = false
            await talkStore.endSession()
        }
    }

    // MARK: - Template Construction

    private func buildVoiceControlTemplate() -> CPVoiceControlTemplate {
        let ready = makeState(
            id: VoiceControlStateID.ready,
            titles: ["Pronto. Toque para conversar com o Hermes", "Toque para conversar"],
            systemImage: "mic.fill",
            repeats: false,
            action: .start
        )

        let connecting = makeState(
            id: VoiceControlStateID.connecting,
            titles: ["Conectando ao Hermes…", "Conectando…"],
            systemImage: "antenna.radiowaves.left.and.right",
            repeats: true,
            action: .end
        )

        let listening = makeState(
            id: VoiceControlStateID.listening,
            titles: ["Ouvindo…", "Pode falar"],
            systemImage: "waveform",
            repeats: true,
            action: .end
        )

        let thinking = makeState(
            id: VoiceControlStateID.thinking,
            titles: ["Pensando…", "Aguarde um instante"],
            systemImage: "brain",
            repeats: true,
            action: .end
        )

        let consulting = makeState(
            id: VoiceControlStateID.consulting,
            titles: ["Consultando o Hermes…", "Buscando no Hermes…"],
            systemImage: "dot.radiowaves.left.and.right",
            repeats: true,
            action: .end
        )

        let speaking = makeState(
            id: VoiceControlStateID.speaking,
            titles: ["Falando…", "Hermes está falando"],
            systemImage: "speaker.wave.2.fill",
            repeats: false,
            action: .end
        )

        let unavailable = makeState(
            id: VoiceControlStateID.unavailable,
            titles: ["Voz indisponível", "Confira o pareamento no iPhone"],
            systemImage: "exclamationmark.triangle",
            repeats: false,
            action: .start
        )

        return CPVoiceControlTemplate(
            voiceControlStates: [ready, connecting, listening, thinking, consulting, speaking, unavailable]
        )
    }

    private func makeState(
        id: String,
        titles: [String],
        systemImage: String,
        repeats: Bool,
        action: SessionAction?
    ) -> CPVoiceControlState {
        let state = CPVoiceControlState(
            identifier: id,
            titleVariants: titles,
            image: UIImage(systemName: systemImage),
            repeats: repeats
        )

        // Action buttons on the voice control screen are iOS 26.4+ (the same
        // release that introduced the voice-based conversational category).
        if #available(iOS 26.4, *), let action {
            state.actionButtons = [makeButton(for: action)]
        }

        return state
    }

    @available(iOS 26.4, *)
    private func makeButton(for action: SessionAction) -> CPButton {
        let imageName = action == .start ? "mic.fill" : "stop.fill"
        let button = CPButton(image: UIImage(systemName: imageName) ?? UIImage()) { _ in
            Task { @MainActor [weak self] in
                switch action {
                case .start:
                    await self?.beginSession()
                case .end:
                    await self?.finishSession()
                }
            }
        }
        button.title = action == .start ? "Iniciar conversa" : "Encerrar"
        return button
    }

    // MARK: - Session Control

    private func beginSession() async {
        guard !talkStore.isSessionActive else { return }
        guard container.pairingStore.isPaired else {
            syncState()
            return
        }

        didStartSession = true
        // `startSessionDirectly` skips the readiness guard but uses the exact
        // same TalkStore path as the iPhone overlay.
        await talkStore.startSessionDirectly()
        if !talkStore.isSessionActive {
            didStartSession = false
        }
        syncState()
    }

    private func finishSession() async {
        didStartSession = false
        await talkStore.endSession()
        syncState()
    }

    // MARK: - State Sync

    private func currentStateIdentifier() -> String {
        if talkStore.isSessionActive {
            if talkStore.connectionState == .connecting || talkStore.connectionState == .checking {
                return VoiceControlStateID.connecting
            }
            if talkStore.isDelegationInProgress {
                return VoiceControlStateID.consulting
            }
            switch talkStore.voiceState {
            case .listening, .interrupted:
                return VoiceControlStateID.listening
            case .speaking:
                return VoiceControlStateID.speaking
            case .thinking, .idle, .disconnected:
                return VoiceControlStateID.thinking
            }
        }

        switch talkStore.connectionState {
        case .checking, .connecting:
            return VoiceControlStateID.connecting
        case .blocked, .failed:
            return VoiceControlStateID.unavailable
        case .idle, .ready, .connected:
            break
        }

        return talkStore.canStartSession ? VoiceControlStateID.ready : VoiceControlStateID.unavailable
    }

    private func syncState() {
        guard let voiceTemplate else { return }

        let stateID = currentStateIdentifier()
        guard stateID != lastSyncedStateID else { return }

        lastSyncedStateID = stateID
        voiceTemplate.activateVoiceControlState(withIdentifier: stateID)
    }
}
