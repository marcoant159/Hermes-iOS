import ActivityKit
import AppIntents
import Foundation

/// Intents exposed to the system (Siri, Shortcuts, Back Tap, Control Center,
/// Lock Screen and the Live Activity buttons). Buttons inside a Live Activity
/// use `LiveActivityIntent`, which the system always performs in the main app's
/// process, so these intents talk to the shared `AppContainer` directly.
///
/// The widget extension ships a no-op copy of these types (see
/// `HermesMobileWidgets/HermesSystemIntents.swift`) so the shared attributes can
/// reference them while rendering; only this app copy actually runs.
struct EndVoiceSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Encerrar conversa por voz"
    static var description = IntentDescription("Encerra a sessão de voz ativa do Hermes.")

    func perform() async throws -> some IntentResult {
        await AppContainer.sharedDefault().talkStore.endSession()
        return .result()
    }
}

struct ToggleVoiceMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Silenciar ou retomar o microfone"
    static var description = IntentDescription("Alterna o microfone da sessão de voz do Hermes.")

    func perform() async throws -> some IntentResult {
        await AppContainer.sharedDefault().talkStore.toggleMute()
        return .result()
    }
}

/// "Conversar com o Hermes" — opens the app straight into the GPT Live voice
/// overlay. Used by Siri, the Shortcuts app and Back Tap.
struct TalkWithHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Conversar com o Hermes"
    static var description = IntentDescription("Abre o Hermes e inicia uma conversa por voz com o GPT Live.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await AppContainer.sharedDefault().startVoiceConversationFromSystem()
        return .result()
    }
}

struct HermesAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkWithHermesIntent(),
            phrases: [
                "Conversar com o \(.applicationName)",
                "Falar com o \(.applicationName)",
                "Abrir a voz do \(.applicationName)"
            ],
            shortTitle: "Conversar com o Hermes",
            systemImageName: "waveform"
        )
    }
}
