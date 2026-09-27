import Foundation

@MainActor
@Observable
final class SettingsStore {
    var settings: UserSettings {
        didSet {
            persistence.saveUserSettings(settings)
            if oldValue.environment != settings.environment {
                Task { await onEnvironmentChanged?(settings.environment) }
            }
            if oldValue.relayConfiguration != settings.relayConfiguration {
                Task { await onRelayConfigurationChanged?(settings.relayConfiguration) }
            }
            if oldValue.wakePhrasePreset != settings.wakePhrasePreset
                || oldValue.wakePhraseCustomText != settings.wakePhraseCustomText {
                Task { await onWakePhraseChanged?(settings) }
            }
        }
    }

    var onEnvironmentChanged: (@MainActor (AppEnvironment) async -> Void)?
    var onRelayConfigurationChanged: (@MainActor (RelayConfiguration) async -> Void)?
    /// Called when the activation phrase changes, so the wake listener picks it
    /// up live without toggling Hands-Free off/on.
    var onWakePhraseChanged: (@MainActor (UserSettings) async -> Void)?
    var availableEnvironments: [AppEnvironment] {
        environmentPolicy.availableEnvironments
    }
    let buildConfiguration: AppBuildConfiguration

    private let persistence: any AppPersistenceStoreProtocol
    private let environmentPolicy: AppEnvironmentPolicy

    init(
        persistence: any AppPersistenceStoreProtocol,
        environmentPolicy: AppEnvironmentPolicy = .currentBuild,
        buildConfiguration: AppBuildConfiguration = .current()
    ) {
        self.persistence = persistence
        self.environmentPolicy = environmentPolicy
        self.buildConfiguration = buildConfiguration
        let storedSettings = persistence.loadUserSettings() ?? DemoData.sampleUserSettings
        self.settings = storedSettings.applyingEnvironmentPolicy(environmentPolicy, buildConfiguration: buildConfiguration)
    }
}
