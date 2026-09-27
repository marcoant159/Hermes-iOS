import ActivityKit
import AppIntents
import Foundation

// Widget-extension copy of the system intents. The widget needs these types at
// compile time so it can attach `Button(intent:)` to the Live Activity and a
// `ControlWidgetButton` to the Control Center control. At runtime the system
// performs the main app's copy (`HermesMobile/System/HermesSystemIntents.swift`)
// for every `LiveActivityIntent`, and for `openAppWhenRun` intents the app is
// launched and its own copy runs — so these bodies intentionally do nothing.

struct EndVoiceSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Encerrar conversa por voz"
    static let description = IntentDescription("Encerra a sessão de voz ativa do Hermes.")

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct ToggleVoiceMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Silenciar ou retomar o microfone"
    static let description = IntentDescription("Alterna o microfone da sessão de voz do Hermes.")

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct TalkWithHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Conversar com o Hermes"
    static let description = IntentDescription("Abre o Hermes e inicia uma conversa por voz com o GPT Live.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
