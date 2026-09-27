import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct HermesBrandIcon: View {
    let size: CGFloat
    var fallbackSymbol: String = "brain.head.profile"
    var fallbackTint: Color = .yellow
    var backgroundTint: Color? = nil
    var cornerRadius: CGFloat? = nil

    var body: some View {
        if let uiImage = Self.loadImage() {
            Image(uiImage: uiImage)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22))
                .ifLet(backgroundTint) { view, tint in
                    view.background(tint, in: RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22))
                }
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.7, weight: .medium))
                .foregroundStyle(fallbackTint)
                .frame(width: size, height: size)
                .ifLet(backgroundTint) { view, tint in
                    view.background(tint, in: Circle())
                }
        }
    }

    private static func loadImage() -> UIImage? {
        if let image = UIImage(named: "AppIcon60x60", in: Bundle.main, compatibleWith: nil) {
            return image
        }

        let containerAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if let appBundle = Bundle(url: containerAppURL),
           let image = UIImage(named: "AppIcon60x60", in: appBundle, compatibleWith: nil) {
            return image
        }

        return nil
    }
}

extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

private extension HermesActivityAttributes.ContentState {
    var isVoice: Bool { sessionType == "voice" }

    var phaseIcon: String {
        switch phase {
        case "listening": "waveform"
        case "thinking": "brain"
        case "speaking": "speaker.wave.2.fill"
        case "delegating": "arrow.triangle.2.circlepath"
        case "working": "gearshape.2.fill"
        case "completed": "checkmark.circle.fill"
        case "connecting": "antenna.radiowaves.left.and.right"
        default: "brain.head.profile"
        }
    }

    var showsProgress: Bool {
        switch phase {
        case "delegating", "working", "thinking": true
        default: false
        }
    }

    var progressFraction: Double? {
        guard let progress else { return nil }
        return min(max(progress, 0), 1)
    }
}

private struct HermesActivityButtonStyle: ButtonStyle {
    var tint: Color = .yellow

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(tint.opacity(configuration.isPressed ? 0.3 : 0.16), in: Capsule())
    }
}

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            // Lock Screen / banner layout
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view (long press on Dynamic Island)
                DynamicIslandExpandedRegion(.leading) {
                    HermesBrandIcon(size: 30)
                        .overlay(alignment: .bottomTrailing) {
                            phaseBadge(context.state, size: 9)
                        }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(context.attributes.agentName)
                                .font(.headline)
                                .foregroundStyle(.white)
                            engineChip(context)
                        }
                        Text(context.state.status)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        if let preview = context.state.answerPreview {
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        } else if let prompt = context.state.prompt, context.state.isVoice {
                            Text("“\(prompt)”")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context)
                }
            } compactLeading: {
                compactLeading(context)
            } compactTrailing: {
                compactTrailing(context)
            } minimal: {
                HermesBrandIcon(size: 16)
            }
        }
        .supplementalActivityFamilies([.small])
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HermesBrandIcon(
                    size: 44,
                    backgroundTint: Color.yellow.opacity(0.15),
                    cornerRadius: 12
                )
                .overlay(alignment: .bottomTrailing) {
                    phaseBadge(context.state, size: 11)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.attributes.agentName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        engineChip(context)
                    }

                    Text(context.state.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Spacer()

                elapsedView(context)
            }

            if let preview = context.state.answerPreview {
                previewRow(systemImage: "checkmark.circle.fill", text: preview)
            } else if let prompt = context.state.prompt, context.state.isVoice || context.state.sessionType == "chat" {
                previewRow(systemImage: "text.bubble", text: prompt)
            }

            if context.state.showsProgress, let progress = context.state.progressFraction {
                ProgressView(value: progress)
                    .tint(.yellow)
            }

            if context.state.isVoice {
                voiceControls(context)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func previewRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func voiceControls(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        let isMuted = context.state.isMuted == true
        HStack(spacing: 10) {
            Button(intent: ToggleVoiceMuteIntent()) {
                Label(isMuted ? "Retomar" : "Silenciar",
                      systemImage: isMuted ? "mic.fill" : "mic.slash.fill")
            }
            .buttonStyle(HermesActivityButtonStyle(tint: isMuted ? .green : .yellow))
            .invalidatableContent()

            Button(intent: EndVoiceSessionIntent()) {
                Label("Encerrar", systemImage: "xmark")
            }
            .buttonStyle(HermesActivityButtonStyle(tint: .red))
            .invalidatableContent()
        }
    }

    // MARK: - Dynamic Island pieces

    @ViewBuilder
    private func compactLeading(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        HermesBrandIcon(size: 15)
    }

    @ViewBuilder
    private func compactTrailing(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        if context.state.showsProgress, let progress = context.state.progressFraction {
            Text("\(Int(progress * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
        } else if let start = context.state.startDate {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: 44)
        } else {
            Text(shortStatus(context.state.status))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private func expandedTrailing(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        if let start = context.state.startDate {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.yellow)
                .frame(maxWidth: 52)
        } else if context.state.elapsedSeconds > 0 {
            Text(formatDuration(context.state.elapsedSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private func expandedBottom(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        VStack(spacing: 8) {
            if context.state.showsProgress, let progress = context.state.progressFraction {
                ProgressView(value: progress)
                    .tint(.yellow)
                    .padding(.horizontal, 4)
            }
            if context.state.isVoice {
                voiceControls(context)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Common pieces

    @ViewBuilder
    private func phaseBadge(_ state: HermesActivityAttributes.ContentState, size: CGFloat) -> some View {
        Image(systemName: state.phaseIcon)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.black)
            .padding(size * 0.42)
            .background(.yellow, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
            .offset(x: size * 0.35, y: size * 0.35)
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private func engineChip(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        if let engine = context.state.engineName, context.state.isVoice {
            Text(engine)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.18), in: Capsule())
        }
    }

    @ViewBuilder
    private func elapsedView(_ context: ActivityViewContext<HermesActivityAttributes>) -> some View {
        // Use the native timer when a start date is available — it ticks in
        // real time without needing Live Activity updates.
        if let start = context.state.startDate {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } else if context.state.elapsedSeconds > 0 {
            Text(formatDuration(context.state.elapsedSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func shortStatus(_ status: String) -> String {
        if status.count <= 12 { return status }
        return String(status.prefix(11)) + "…"
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
