import Foundation

struct AppBuildConfiguration: Equatable, Sendable {
    let hostedRelayBaseURL: String?
    let hostedRelayEnabled: Bool
    let supportURL: URL?
    let termsOfServiceURL: URL?
    let privacyPolicyURL: URL?

    static func current(bundle: Bundle = .main) -> AppBuildConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let hostedRelayBaseURL = RelayConfiguration.normalizeBaseURL(
            info["APP_HOSTED_RELAY_URL"] as? String
        )
        let hostedRelayEnabled = (info["APP_HOSTED_RELAY_ENABLED"] as? Bool) ?? false

        func urlValue(_ key: String) -> URL? {
            guard let raw = info[key] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return URL(string: raw)
        }

        return AppBuildConfiguration(
            hostedRelayBaseURL: hostedRelayBaseURL,
            hostedRelayEnabled: hostedRelayEnabled && hostedRelayBaseURL != nil,
            supportURL: urlValue("APP_SUPPORT_URL"),
            termsOfServiceURL: urlValue("APP_TERMS_URL"),
            privacyPolicyURL: urlValue("APP_PRIVACY_URL")
        )
    }
}

enum RelayMode: String, Codable, CaseIterable, Hashable, Sendable {
    case custom
    case hosted

    var displayLabel: String {
        switch self {
        case .custom: "Use My Relay"
        case .hosted: "Use Hosted Relay"
        }
    }
}

struct RelayConfiguration: Codable, Hashable, Sendable {
    var relayMode: RelayMode
    var customRelayBaseURL: String
    var hostedRelayBaseURL: String?
    var hostedRelayEnabled: Bool

    init(
        relayMode: RelayMode = .custom,
        customRelayBaseURL: String = "",
        hostedRelayBaseURL: String? = nil,
        hostedRelayEnabled: Bool = false
    ) {
        self.relayMode = relayMode
        self.customRelayBaseURL = RelayConfiguration.normalizeBaseURL(customRelayBaseURL) ?? customRelayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostedRelayBaseURL = RelayConfiguration.normalizeBaseURL(hostedRelayBaseURL)
        self.hostedRelayEnabled = hostedRelayEnabled && self.hostedRelayBaseURL != nil
        if relayMode == .hosted && !self.canUseHosted {
            self.relayMode = .custom
        }
    }

    static func defaultValue(
        buildConfiguration: AppBuildConfiguration = .current(),
        environmentPolicy: AppEnvironmentPolicy = .currentBuild
    ) -> RelayConfiguration {
        RelayConfiguration(
            relayMode: .custom,
            customRelayBaseURL: environmentPolicy.allowsEnvironmentOverrides ? AppEnvironment.development.baseURLString : "",
            hostedRelayBaseURL: buildConfiguration.hostedRelayBaseURL,
            hostedRelayEnabled: buildConfiguration.hostedRelayEnabled
        )
    }

    static func migratedLegacyValue(
        environment: AppEnvironment,
        buildConfiguration: AppBuildConfiguration = .current(),
        environmentPolicy: AppEnvironmentPolicy = .currentBuild
    ) -> RelayConfiguration {
        if environmentPolicy.allowsEnvironmentOverrides, environment != .production {
            return RelayConfiguration(
                relayMode: .custom,
                customRelayBaseURL: environment.baseURLString,
                hostedRelayBaseURL: buildConfiguration.hostedRelayBaseURL,
                hostedRelayEnabled: buildConfiguration.hostedRelayEnabled
            )
        }

        if buildConfiguration.hostedRelayEnabled, buildConfiguration.hostedRelayBaseURL != nil {
            return RelayConfiguration(
                relayMode: .hosted,
                customRelayBaseURL: "",
                hostedRelayBaseURL: buildConfiguration.hostedRelayBaseURL,
                hostedRelayEnabled: true
            )
        }

        return RelayConfiguration.defaultValue(
            buildConfiguration: buildConfiguration,
            environmentPolicy: environmentPolicy
        )
    }

    mutating func applyBuildConfiguration(_ buildConfiguration: AppBuildConfiguration) {
        hostedRelayBaseURL = buildConfiguration.hostedRelayBaseURL
        hostedRelayEnabled = buildConfiguration.hostedRelayEnabled && hostedRelayBaseURL != nil
        customRelayBaseURL = RelayConfiguration.normalizeBaseURL(customRelayBaseURL) ?? customRelayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if relayMode == .hosted && !canUseHosted {
            relayMode = .custom
        }
    }

    var canUseHosted: Bool {
        hostedRelayEnabled && hostedRelayBaseURL != nil
    }

    var activeBaseURLString: String? {
        switch relayMode {
        case .custom:
            return RelayConfiguration.normalizeBaseURL(customRelayBaseURL)
        case .hosted:
            guard canUseHosted else { return RelayConfiguration.normalizeBaseURL(customRelayBaseURL) }
            return hostedRelayBaseURL
        }
    }

    var relayOriginLabel: String {
        guard let baseURLString = activeBaseURLString, let url = URL(string: baseURLString) else {
            return "Not Configured"
        }
        return url.host ?? baseURLString
    }

    var validationMessage: String? {
        switch relayMode {
        case .custom:
            let trimmed = customRelayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Enter your relay URL." }
            guard RelayConfiguration.normalizeBaseURL(trimmed) != nil else {
                return "Relay URL must be an absolute http(s) URL ending with /v1."
            }
            return nil
        case .hosted:
            return canUseHosted ? nil : "Hosted relay is not configured in this app build."
        }
    }

    static func normalizeBaseURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.hasPrefix("http://"), !trimmed.hasPrefix("https://") {
            return nil
        }

        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return nil
        }

        let normalizedPath: String
        switch components.path {
        case "", "/":
            normalizedPath = "/v1"
        default:
            normalizedPath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        }
        guard normalizedPath.hasSuffix("/v1") else {
            return nil
        }
        components.path = normalizedPath
        return components.string
    }
}

struct AppEnvironmentPolicy: Equatable, Sendable {
    let allowsEnvironmentOverrides: Bool

    var availableEnvironments: [AppEnvironment] {
        allowsEnvironmentOverrides ? AppEnvironment.allCases : [.production]
    }

    var defaultEnvironment: AppEnvironment {
        .production
    }

    func sanitize(_ settings: UserSettings) -> UserSettings {
        var sanitized = settings
        if !availableEnvironments.contains(sanitized.environment) {
            sanitized.environment = defaultEnvironment
        }
        return sanitized
    }

    static let currentBuild: AppEnvironmentPolicy = {
        #if DEBUG
        AppEnvironmentPolicy(allowsEnvironmentOverrides: true)
        #else
        AppEnvironmentPolicy(allowsEnvironmentOverrides: false)
        #endif
    }()
}

enum LocationSyncPreference: String, Codable, Hashable, Sendable {
    case foregroundOnly
    case backgroundAllowed

    var displayLabel: String {
        switch self {
        case .foregroundOnly: "Foreground Only"
        case .backgroundAllowed: "Background Allowed"
        }
    }
}

struct UserSettings: Codable, Hashable, Sendable {
    var userName: String
    var avatarInitials: String
    var notificationsEnabled: Bool
    var hapticFeedbackEnabled: Bool
    var environment: AppEnvironment
    var relayConfiguration: RelayConfiguration
    var autoConnectOnLaunch: Bool
    var locationSyncPreference: LocationSyncPreference
    /// Hands-free "hey hermes" wake word listener (opt-in; needs mic in background).
    var wakeWordEnabled: Bool
    var chatModelChoice: ChatModelChoice
    /// Realtime voice transport ("Motor de voz") requested when starting talk mode.
    var voiceEngineChoice: VoiceEngineChoice

    init(
        userName: String = "User",
        avatarInitials: String = "U",
        notificationsEnabled: Bool = true,
        hapticFeedbackEnabled: Bool = true,
        environment: AppEnvironment = AppEnvironmentPolicy.currentBuild.defaultEnvironment,
        relayConfiguration: RelayConfiguration = RelayConfiguration.defaultValue(),
        autoConnectOnLaunch: Bool = true,
        locationSyncPreference: LocationSyncPreference = .foregroundOnly,
        wakeWordEnabled: Bool = false,
        chatModelChoice: ChatModelChoice = .hermesDefault,
        voiceEngineChoice: VoiceEngineChoice = .auto
    ) {
        self.userName = userName
        self.avatarInitials = avatarInitials
        self.notificationsEnabled = notificationsEnabled
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.environment = environment
        self.relayConfiguration = relayConfiguration
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.locationSyncPreference = locationSyncPreference
        self.wakeWordEnabled = wakeWordEnabled
        self.chatModelChoice = chatModelChoice
        self.voiceEngineChoice = voiceEngineChoice
    }

    private enum CodingKeys: String, CodingKey {
        case userName
        case avatarInitials
        case notificationsEnabled
        case hapticFeedbackEnabled
        case environment
        case relayConfiguration
        case autoConnectOnLaunch
        case locationSyncPreference
        case wakeWordEnabled
        case chatModelChoice
        case voiceEngineChoice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? "User"
        avatarInitials = try container.decodeIfPresent(String.self, forKey: .avatarInitials) ?? "U"
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        hapticFeedbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticFeedbackEnabled) ?? true
        environment = try container.decodeIfPresent(AppEnvironment.self, forKey: .environment) ?? AppEnvironmentPolicy.currentBuild.defaultEnvironment
        relayConfiguration = try container.decodeIfPresent(RelayConfiguration.self, forKey: .relayConfiguration)
            ?? RelayConfiguration.migratedLegacyValue(environment: environment)
        autoConnectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunch) ?? true
        locationSyncPreference = try container.decodeIfPresent(LocationSyncPreference.self, forKey: .locationSyncPreference) ?? .foregroundOnly
        wakeWordEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? false
        chatModelChoice = try container.decodeIfPresent(ChatModelChoice.self, forKey: .chatModelChoice) ?? .hermesDefault
        voiceEngineChoice = try container.decodeIfPresent(VoiceEngineChoice.self, forKey: .voiceEngineChoice) ?? .auto
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userName, forKey: .userName)
        try container.encode(avatarInitials, forKey: .avatarInitials)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(hapticFeedbackEnabled, forKey: .hapticFeedbackEnabled)
        try container.encode(environment, forKey: .environment)
        try container.encode(relayConfiguration, forKey: .relayConfiguration)
        try container.encode(autoConnectOnLaunch, forKey: .autoConnectOnLaunch)
        try container.encode(locationSyncPreference, forKey: .locationSyncPreference)
        try container.encode(wakeWordEnabled, forKey: .wakeWordEnabled)
        try container.encode(chatModelChoice, forKey: .chatModelChoice)
        try container.encode(voiceEngineChoice, forKey: .voiceEngineChoice)
    }

    func applyingEnvironmentPolicy(
        _ policy: AppEnvironmentPolicy = .currentBuild,
        buildConfiguration: AppBuildConfiguration = .current()
    ) -> UserSettings {
        var sanitized = policy.sanitize(self)
        sanitized.relayConfiguration.applyBuildConfiguration(buildConfiguration)
        if sanitized.relayConfiguration.relayMode == .hosted, !sanitized.relayConfiguration.canUseHosted {
            sanitized.relayConfiguration.relayMode = .custom
        }
        return sanitized
    }
}

enum ChatModelChoice: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case hermesDefault
    case gpt6Luna
    case gpt6Astra
    case gemini38Flash
    case deepseekV41Flash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hermesDefault: "Hermes padrão (GPT-6 Luna)"
        case .gpt6Luna: "GPT-6 Luna"
        case .gpt6Astra: "GPT-6 Astra"
        case .gemini38Flash: "Gemini 3.8 Flash"
        case .deepseekV41Flash: "DeepSeek V4.1 Flash"
        }
    }

    var modelOverride: String? {
        switch self {
        case .hermesDefault: nil
        case .gpt6Luna: "openai-codex/gpt-6-luna"
        case .gpt6Astra: "openai-codex/gpt-6-astra"
        case .gemini38Flash: "gemini/gemini-3.8-flash"
        case .deepseekV41Flash: "opencode-go/deepseek-v4.1-flash"
        }
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "gemini-3.8-flash", "gemini38Flash":
            self = .gemini38Flash
        default:
            // Unknown values (e.g. a model removed in a later build) must not
            // fail decoding of the whole UserSettings blob.
            self = ChatModelChoice(rawValue: rawValue) ?? .hermesDefault
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which realtime transport the talk mode should request from the connector.
enum VoiceEngineChoice: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case auto
    case codexLive = "codex_live"
    case codexRealtime = "codex_realtime"
    case geminiLive = "gemini_live"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automático"
        case .codexLive: "GPT Live (Codex)"
        case .codexRealtime: "GPT Realtime (Codex)"
        case .geminiLive: "Gemini Live"
        }
    }

    var providerValue: String { rawValue }
}

enum AppEnvironment: String, Codable, CaseIterable, Hashable, Sendable {
    case production
    case staging
    case development

    var displayLabel: String {
        switch self {
        case .production: "Production"
        case .staging: "Staging"
        case .development: "Development"
        }
    }

    var baseURLString: String {
        switch self {
        case .production: ""  // Use custom relay URL from RelayConfiguration
        case .staging: ""     // Use custom relay URL from RelayConfiguration
        case .development: "http://127.0.0.1:8000/v1"
        }
    }
}
