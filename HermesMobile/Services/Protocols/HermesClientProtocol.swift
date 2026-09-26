import Foundation

/// Lightweight summary of a conversation shown in the conversations list.
struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int
    let isCurrent: Bool
}

@MainActor
protocol HermesClientProtocol {
    var connectionStatus: ConnectionStatus { get }
    var currentConversation: Conversation? { get }
    func connect() async
    func disconnect() async
    func send(message: String, attachments: [PendingAttachment], clientMessageID: UUID) async -> Message
    func sendStreaming(message: String, attachments: [PendingAttachment], clientMessageID: UUID) -> AsyncStream<StreamingUpdate>
    func loadConversation() async -> Conversation
    func clearConversation() async throws -> Conversation
    func createConversation() async throws -> Conversation
    func selectConversation(id: UUID) async throws -> Conversation
    func listConversations() async throws -> [ConversationSummary]
    func injectVoiceTranscript(voiceSessionId: UUID) async throws -> Conversation
}
