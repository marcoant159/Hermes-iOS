import CarPlay
import UIKit

/// Manages the CarPlay scene lifecycle. When the vehicle connects, we set up a
/// `CPVoiceControlTemplate` as the root — Hermes is a voice-first AI agent, so
/// the CarPlay experience is just Voice Mode.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceManager: CarPlayVoiceManager?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        let manager = CarPlayVoiceManager(interfaceController: interfaceController)
        self.voiceManager = manager

        Task { @MainActor in
            // Apple forbids activating the app by its wake word while it is open
            // on the car screen, so keep the listener disarmed while connected.
            await AppContainer.sharedDefault().handleCarPlayConnected()
            await manager.configure()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // The vehicle was unplugged/turned off. Release every CarPlay-specific
        // reference and close the session this screen opened (a session started
        // on the iPhone, before connecting, is left untouched).
        let manager = voiceManager
        voiceManager = nil
        self.interfaceController = nil

        Task { @MainActor in
            await manager?.tearDown()
            // Restore the previous wake-word state now that the car is gone.
            await AppContainer.sharedDefault().handleCarPlayDisconnected()
        }
    }
}
