import SwiftUI

struct HUDThemePickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(HUDThemeID.allCases) { id in
                let theme = HUDTheme.theme(for: id)
                HUDThemeRow(
                    theme: theme,
                    isSelected: appState.hudThemeID == id
                ) {
                    appState.hudThemeID = id
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HUDThemeRow: View {
    let theme: HUDTheme
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                HUDMiniPreview(theme: theme)
                    .frame(width: 168, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(theme.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(rowBorder, lineWidth: isSelected ? 1.4 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel("\(theme.displayName) — \(theme.tagline)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.10) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }

    private var rowBorder: Color {
        if isSelected { return Color.accentColor.opacity(0.55) }
        return Color.primary.opacity(0.10)
    }
}

private struct HUDMiniPreview: View {
    @Environment(AppState.self) private var appState
    let theme: HUDTheme

    var body: some View {
        ZStack {
            backgroundLayer
                .padding(-40)

            LinearGradient(
                colors: theme.highlight,
                startPoint: .top,
                endPoint: .center
            )
            .padding(.horizontal, -40)

            HStack(spacing: 7) {
                if appState.hudShowIndicator {
                    HUDIndicatorShape(style: theme.indicator, color: theme.accent, size: 7)
                        .shadow(color: theme.accentGlow.opacity(0.85), radius: 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if appState.hudShowTimer {
                    Text("0:24")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textColor.opacity(0.85))
                        .kerning(0.2)
                        .monospacedDigit()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                miniBars
                    .frame(width: 56, height: 16)
            }
            .padding(.horizontal, 12)
            .animation(.easeInOut(duration: 0.2), value: appState.hudShowIndicator)
            .animation(.easeInOut(duration: 0.2), value: appState.hudShowTimer)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: theme.border,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 0.55),
            radius: theme.shadowRadius * 0.35,
            x: 0,
            y: -2
        )
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let endColor = theme.gradientEnd, theme.blur == nil {
            LinearGradient(
                colors: [
                    theme.tint.opacity(theme.tintOpacity),
                    endColor.opacity(theme.tintOpacity)
                ],
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
        } else if theme.blur == nil {
            theme.tint
        } else {
            // Simulate a frosted-glass backdrop by stacking a neutral base + theme tint.
            ZStack {
                simulatedDesktop
                if let endColor = theme.gradientEnd {
                    LinearGradient(
                        colors: [
                            theme.tint.opacity(theme.tintOpacity),
                            endColor.opacity(theme.tintOpacity)
                        ],
                        startPoint: gradientStart,
                        endPoint: gradientEnd
                    )
                } else {
                    theme.tint.opacity(theme.tintOpacity)
                }
            }
        }
    }

    private var simulatedDesktop: some View {
        // Warm light gray for light themes, cool dark gray for dark themes.
        theme.id == .ivory
            ? Color(red: 0.86, green: 0.82, blue: 0.76)
            : Color(red: 0.12, green: 0.13, blue: 0.16)
    }

    private var gradientStart: UnitPoint {
        let rad = theme.gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 - 0.5 * cos(rad), y: 0.5 + 0.5 * sin(rad))
    }

    private var gradientEnd: UnitPoint {
        let rad = theme.gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 + 0.5 * cos(rad), y: 0.5 - 0.5 * sin(rad))
    }

    private var miniBars: some View {
        let heights: [CGFloat] = [4, 7, 11, 8, 5, 9, 12, 6, 4, 10, 7, 5]
        return HStack(alignment: .center, spacing: 1.8) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.textColor.opacity(0.9),
                                theme.textColor.opacity(0.5)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.8, height: h)
            }
        }
    }
}
