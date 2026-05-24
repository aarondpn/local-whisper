import SwiftUI

/// Gates the overlay's SwiftUI subtree on its visibility flags. The NSPanel hosting
/// this view stays alive for the app lifetime, so without this gate any Timer/
/// TimelineView/repeatForever animation inside RecordingOverlayView would keep
/// firing 24/7 — even while the panel is `orderOut`. Hiding an NSPanel doesn't
/// tear down its content view tree, so we tear it down ourselves by rendering
/// nothing when no flag is set.
struct RecordingOverlayHost: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isRecording || appState.isTranscribing || appState.isOverlayPositioningSession {
            RecordingOverlayView()
        }
    }
}

struct RecordingOverlayView: View {
    @Environment(AppState.self) private var appState

    @State private var recordingStart: Date = .now
    @State private var frozenDuration: TimeInterval? = nil
    @State private var pulse: Bool = false

    private var theme: HUDTheme { appState.hudTheme }
    private var scale: CGFloat { appState.hudSize.scale }

    var body: some View {
        HStack(spacing: 12 * scale) {
            if appState.hudShowIndicator {
                recordIndicator
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if appState.hudShowTimer {
                timerLabel
                    .frame(width: 32 * scale, alignment: .leading)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            ZStack {
                AudioVisualizationView(level: appState.audioLevel, tint: theme.textColor)
                    .opacity(showVisualization ? 1 : 0)
                    .scaleEffect(y: showVisualization ? 1 : 0.1, anchor: .center)

                if appState.isTranscribing {
                    TranscribingIndicator(theme: theme, scale: scale)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if appState.silentInputWarning {
                    SilentInputIndicator(theme: theme, scale: scale)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: 132 * scale, height: 26 * scale)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: appState.isTranscribing)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: appState.silentInputWarning)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .animation(.easeInOut(duration: 0.2), value: appState.hudShowIndicator)
        .animation(.easeInOut(duration: 0.2), value: appState.hudShowTimer)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            recordingStart = .now
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: appState.isRecording) { _, isRecording in
            if isRecording {
                recordingStart = .now
                frozenDuration = nil
            } else {
                frozenDuration = Date().timeIntervalSince(recordingStart)
            }
        }
    }

    private var showVisualization: Bool {
        !appState.isTranscribing && !appState.silentInputWarning
    }

    private var accessibilityLabel: String {
        if appState.isTranscribing { return "Transcribing audio" }
        if appState.silentInputWarning { return "No audio detected. Check microphone." }
        if appState.isRecording { return "Recording audio" }
        return "LocalWhisper overlay"
    }

    private var accessibilityValue: String {
        let elapsed = Int(frozenDuration ?? Date().timeIntervalSince(recordingStart))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return "\(minutes) minutes \(seconds) seconds elapsed"
    }

    private var recordIndicator: some View {
        ZStack {
            HUDIndicatorShape(style: theme.indicator, color: theme.accent, size: 9 * scale)
                .shadow(color: theme.accentGlow.opacity(0.85), radius: 4 * scale)
                .shadow(color: theme.accentGlow.opacity(0.55), radius: 9 * scale)
                .opacity(opacityForDot)
                .scaleEffect(scaleForDot)
        }
        .frame(width: 12 * scale, height: 12 * scale)
        .accessibilityHidden(true)
    }

    private var opacityForDot: Double {
        if appState.isTranscribing { return 0.35 }
        return pulse ? 1.0 : 0.55
    }

    private var scaleForDot: CGFloat {
        if appState.isTranscribing { return 0.85 }
        return pulse ? 1.0 : 0.88
    }

    private var timerLabel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(formatted(for: context.date))
                .font(.system(size: 11.5 * scale, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.textColor.opacity(0.85))
                .kerning(0.2)
        }
        .accessibilityHidden(true)
    }

    private func formatted(for now: Date) -> String {
        let elapsed = frozenDuration ?? max(0, now.timeIntervalSince(recordingStart))
        let totalSeconds = Int(elapsed)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct HUDIndicatorShape: View {
    let style: HUDIndicatorStyle
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            switch style {
            case .dot:
                Circle().fill(color)
            case .square:
                Rectangle().fill(color)
            case .ring:
                Circle().strokeBorder(color, lineWidth: max(1.3, size / 6))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct TranscribingIndicator: View {
    let theme: HUDTheme
    let scale: CGFloat
    @State private var rotation: Double = 0
    @State private var breathe: Bool = false

    var body: some View {
        HStack(spacing: 7 * scale) {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    theme.textColor.opacity(0.88),
                    style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round)
                )
                .frame(width: 13 * scale, height: 13 * scale)
                .rotationEffect(.degrees(rotation))

            Text("Transcribing")
                .font(.system(size: 10.5 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textColor.opacity(breathe ? 0.9 : 0.6))
                .kerning(0.4)
                .textCase(.uppercase)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

private struct SilentInputIndicator: View {
    let theme: HUDTheme
    let scale: CGFloat
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.35))
                .opacity(pulse ? 1.0 : 0.55)

            Text("No input — check mic")
                .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textColor.opacity(0.88))
                .kerning(0.3)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
