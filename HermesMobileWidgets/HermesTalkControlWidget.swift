import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen control that opens Hermes straight into the
/// GPT Live voice conversation. It reuses `TalkWithHermesIntent`, the same
/// intent behind the "Conversar com o Hermes" App Shortcut.
struct HermesTalkControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "br.com.marcoant.hermes.Widgets.talk"
        ) {
            ControlWidgetButton(action: TalkWithHermesIntent()) {
                Label("Conversar com o Hermes", systemImage: "waveform")
            }
        }
        .displayName("Conversar com o Hermes")
        .description("Inicia uma conversa por voz com o GPT Live.")
    }
}
