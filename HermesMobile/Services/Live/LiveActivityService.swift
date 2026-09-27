import ActivityKit
import Foundation

/// Manages Hermes Live Activities on the Lock Screen and Dynamic Island.
@MainActor
@Observable
final class LiveActivityService {
    private var currentActivity: Activity<HermesActivityAttributes>?
    private var startedAt: Date?

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Voice Session

    func startVoiceSession(engineName: String? = nil) {
        guard isAvailable else { return }
        let now = Date.now
        adoptExistingActivityIfNeeded()
        let attributes = HermesActivityAttributes(agentName: "Hermes")
        let state = HermesActivityAttributes.ContentState(
            status: "Conectando…",
            toolName: nil,
            elapsedSeconds: 0,
            startDate: now,
            sessionType: "voice",
            phase: "connecting",
            engineName: engineName,
            isMuted: false
        )
        if currentActivity != nil {
            startedAt = now
            updateActivity(with: state)
            return
        }
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            startedAt = now
        } catch {
            // Live Activities not supported or disabled — silently ignore
        }
    }

    func updateVoiceState(
        _ status: String,
        phase: String? = nil,
        toolName: String? = nil,
        engineName: String? = nil,
        prompt: String? = nil,
        answerPreview: String? = nil,
        progress: Double? = nil,
        isMuted: Bool? = nil
    ) {
        let elapsed = Int(Date().timeIntervalSince(startedAt ?? .now))
        let state = HermesActivityAttributes.ContentState(
            status: status,
            toolName: toolName,
            elapsedSeconds: elapsed,
            startDate: startedAt,
            sessionType: "voice",
            phase: phase,
            engineName: engineName,
            prompt: prompt,
            answerPreview: answerPreview,
            progress: progress,
            isMuted: isMuted
        )
        updateActivity(with: state)
    }

    // MARK: - Chat / Tool Calls

    func startToolCall(toolName: String, prompt: String? = nil) {
        guard isAvailable else { return }
        let now = Date.now
        adoptExistingActivityIfNeeded()
        let attributes = HermesActivityAttributes(agentName: "Hermes")
        let state = HermesActivityAttributes.ContentState(
            status: "Trabalhando…",
            toolName: toolName,
            elapsedSeconds: 0,
            startDate: now,
            sessionType: "tool",
            phase: "working",
            prompt: prompt,
            progress: nil
        )
        if currentActivity != nil {
            startedAt = now
            updateActivity(with: state)
            return
        }
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            startedAt = now
        } catch {
            // Silently ignore
        }
    }

    func updateToolProgress(_ status: String, toolName: String? = nil, prompt: String? = nil) {
        let elapsed = Int(Date().timeIntervalSince(startedAt ?? .now))
        let state = HermesActivityAttributes.ContentState(
            status: status,
            toolName: toolName,
            elapsedSeconds: elapsed,
            startDate: startedAt,
            sessionType: "tool",
            phase: "working",
            prompt: prompt
        )
        updateActivity(with: state)
    }

    /// Starts (or reuses) a Live Activity for a chat response that is streaming
    /// while the app is in the background.
    func startChatResponse(prompt: String?, answerPreview: String? = nil) {
        guard isAvailable else { return }
        let now = Date.now
        adoptExistingActivityIfNeeded()
        let attributes = HermesActivityAttributes(agentName: "Hermes")
        let state = HermesActivityAttributes.ContentState(
            status: "Hermes está respondendo…",
            toolName: nil,
            elapsedSeconds: 0,
            startDate: now,
            sessionType: "chat",
            phase: "thinking",
            prompt: prompt,
            answerPreview: answerPreview
        )
        if currentActivity != nil {
            startedAt = now
            updateActivity(with: state)
            return
        }
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            startedAt = now
        } catch {
            // Silently ignore
        }
    }

    func updateChatResponse(status: String, prompt: String?, answerPreview: String?, progress: Double?) {
        let elapsed = Int(Date().timeIntervalSince(startedAt ?? .now))
        let state = HermesActivityAttributes.ContentState(
            status: status,
            toolName: nil,
            elapsedSeconds: elapsed,
            startDate: startedAt,
            sessionType: "chat",
            phase: "thinking",
            prompt: prompt,
            answerPreview: answerPreview,
            progress: progress
        )
        updateActivity(with: state)
    }

    /// Shows a short answer preview for a few seconds, then ends the activity.
    func finishChatResponse(answerPreview: String?) {
        guard let activity = currentActivity else { return }
        let preview = answerPreview.map { String($0.prefix(180)) }
        let state = HermesActivityAttributes.ContentState(
            status: "Resposta pronta",
            toolName: nil,
            elapsedSeconds: Int(Date().timeIntervalSince(startedAt ?? .now)),
            startDate: nil,
            sessionType: "chat",
            phase: "completed",
            answerPreview: preview
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let activityID = activity.id
        startedAt = nil
        currentActivity = nil
        Task.detached {
            for activity in Activity<HermesActivityAttributes>.activities where activity.id == activityID {
                await activity.end(content, dismissalPolicy: .after(.now + 8))
            }
        }
    }

    func endCurrentChatActivity() {
        guard let activity = currentActivity else { return }
        let state = HermesActivityAttributes.ContentState(
            status: "Pronto",
            toolName: nil,
            elapsedSeconds: Int(Date().timeIntervalSince(startedAt ?? .now)),
            startDate: nil,
            sessionType: "chat",
            phase: "completed"
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let activityID = activity.id
        startedAt = nil
        currentActivity = nil
        Task.detached {
            for activity in Activity<HermesActivityAttributes>.activities where activity.id == activityID {
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - End

    func endActivity() {
        startedAt = nil
        currentActivity = nil

        let finalContent = ActivityContent(
            state: HermesActivityAttributes.ContentState(
                status: "Encerrado",
                toolName: nil,
                elapsedSeconds: 0,
                startDate: nil,
                sessionType: "voice",
                phase: "completed"
            ),
            staleDate: nil
        )
        Task.detached {
            for activity in Activity<HermesActivityAttributes>.activities {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Private

    private func updateActivity(with state: HermesActivityAttributes.ContentState) {
        guard let activity = currentActivity, activity.activityState == .active else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        let activityID = activity.id
        Task.detached {
            for activity in Activity<HermesActivityAttributes>.activities where activity.id == activityID {
                await activity.update(content)
            }
        }
    }

    // MARK: - App Lifecycle

    /// Called when the app returns to foreground. No timer to restart —
    /// the widget uses Text(timerInterval:) which ticks natively via the OS.
    func handleAppDidBecomeActive() {
        adoptExistingActivityIfNeeded()
    }

    static func endAllActivities() {
        let finalContent = ActivityContent(
            state: HermesActivityAttributes.ContentState(
                status: "Encerrado",
                toolName: nil,
                elapsedSeconds: 0,
                startDate: nil,
                sessionType: "voice",
                phase: "completed"
            ),
            staleDate: nil
        )
        Task.detached {
            for activity in Activity<HermesActivityAttributes>.activities {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }

    private func adoptExistingActivityIfNeeded() {
        guard currentActivity == nil else { return }
        if let activity = Activity<HermesActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            currentActivity = activity
            startedAt = activity.content.state.startDate
        }
    }
}
