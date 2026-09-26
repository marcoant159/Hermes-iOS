import Foundation

@MainActor
final class ResilientHermesClient: HermesClientProtocol {
    var connectionStatus: ConnectionStatus {
        primary.connectionStatus
    }

    var currentConversation: Conversation? {
        primary.currentConversation ?? fallback.currentConversation
    }

    private let primary: any HermesClientProtocol
    private let fallback: any HermesClientProtocol
    private let allowsFallback: @MainActor () -> Bool

    init(
        primary: any HermesClientProtocol,
        fallback: any HermesClientProtocol,
        allowsFallback: @escaping @MainActor () -> Bool = { true }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.allowsFallback = allowsFallback
    }

    func connect() async {
        await primary.connect()
        if allowsFallback() && primary.connectionStatus == .error {
            await fallback.connect()
        }
    }

    func disconnect() async {
        await primary.disconnect()
        await fallback.disconnect()
    }

    func send(message: String, attachments: [PendingAttachment] = [], clientMessageID: UUID) async -> Message {
        let response = await primary.send(message: message, attachments: attachments, clientMessageID: clientMessageID)
        if allowsFallback() && response.status == .failed {
            return await fallback.send(message: message, attachments: attachments, clientMessageID: clientMessageID)
        }
        return response
    }

    func sendStreaming(message: String, attachments: [PendingAttachment] = [], clientMessageID: UUID) -> AsyncStream<StreamingUpdate> {
        let primaryStream = primary.sendStreaming(message: message, attachments: attachments, clientMessageID: clientMessageID)
        guard allowsFallback() else { return primaryStream }

        return AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var sawOutput = false
                var primaryFailure: String?

                for await update in primaryStream {
                    if case .failed(let failure) = update {
                        // Nothing useful was streamed yet: hold the failure so we can
                        // try the fallback first (mirrors `send`, `connect`, `loadConversation`).
                        if sawOutput {
                            continuation.yield(.failed(failure))
                            continuation.finish()
                            return
                        }
                        primaryFailure = failure
                        break
                    }
                    sawOutput = true
                    continuation.yield(update)
                }

                if let primaryFailure {
                    guard self.allowsFallback() else {
                        continuation.yield(.failed(primaryFailure))
                        continuation.finish()
                        return
                    }
                    for await update in self.fallback.sendStreaming(
                        message: message,
                        attachments: attachments,
                        clientMessageID: clientMessageID
                    ) {
                        continuation.yield(update)
                    }
                }

                continuation.finish()
            }
        }
    }

    func loadConversation() async -> Conversation {
        let conversation = await primary.loadConversation()
        if allowsFallback() && primary.connectionStatus == .error {
            return await fallback.loadConversation()
        }
        return conversation
    }

    func clearConversation() async throws -> Conversation {
        try await primary.clearConversation()
    }

    func createConversation() async throws -> Conversation {
        try await primary.createConversation()
    }

    func selectConversation(id: UUID) async throws -> Conversation {
        try await primary.selectConversation(id: id)
    }

    func listConversations() async throws -> [ConversationSummary] {
        try await primary.listConversations()
    }

    func injectVoiceTranscript(voiceSessionId: UUID) async throws -> Conversation {
        try await primary.injectVoiceTranscript(voiceSessionId: voiceSessionId)
    }
}
