import SwiftUI

/// The text area of the live-transcription card: settled text solid, tentative
/// text dimmed (reserved — parakeet's RNN-T finalizes only), plus a breathing
/// caret as the "listening" affordance. Behaves like an autocue: newest text
/// bottom-anchored, older lines scrolling away under a top fade, no user
/// scrolling. Everything animation-like is transition- or TimelineView-driven
/// inside the visibility-gated subtree, so nothing runs when the HUD is hidden.
struct LiveTranscriptTextView: View {
    let live: AppState.LiveTranscript
    let theme: HUDTheme
    let scale: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            transcriptText
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14 * scale)  // room to scroll under the fade mask
        }
        .scrollDisabled(true)
        .defaultScrollAnchor(.bottom)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live transcription")
        .accessibilityValue(live.settled.isEmpty ? "Listening" : live.settled)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var transcriptText: some View {
        // ~1.5 Hz timeline drives only the caret blink; the text re-render at
        // that rate is negligible next to the 60 Hz level meter alongside it.
        TimelineView(.periodic(from: .now, by: 0.65)) { context in
            let caretVisible = Int(context.date.timeIntervalSinceReferenceDate / 0.65) % 2 == 0
            composed(caretVisible: caretVisible)
                .font(.system(size: 13 * scale, weight: .regular, design: .rounded))
                .lineSpacing(3 * scale)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.22), value: live.settled)
                .opacity(live.streamFailed ? 0.6 : 1.0)
        }
    }

    private func composed(caretVisible: Bool) -> Text {
        let settled = Text(live.settled)
            .foregroundColor(theme.textColor.opacity(0.95))
        let tentative = live.tentative.isEmpty
            ? Text("")
            : Text(" " + live.tentative).foregroundColor(theme.textColor.opacity(0.45))
        let caret: Text
        if live.streamFailed {
            caret = Text("")
        } else if live.settled.isEmpty && live.tentative.isEmpty {
            caret = Text("Listening")
                .foregroundColor(theme.textColor.opacity(0.4))
                .italic()
                + caretGlyph(visible: caretVisible)
        } else {
            caret = caretGlyph(visible: caretVisible)
        }
        return settled + tentative + caret
    }

    private func caretGlyph(visible: Bool) -> Text {
        Text(" ▍")
            .foregroundColor(theme.accent.opacity(visible ? 0.95 : 0.35))
    }
}
