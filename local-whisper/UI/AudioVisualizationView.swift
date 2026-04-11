import Combine
import SwiftUI

struct AudioVisualizationView: View {
    let level: Float
    private let barCount: Int
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private let tint: Color

    @State private var buffer: [CGFloat]

    init(level: Float, tint: Color = .white, barCount: Int = 44, barWidth: CGFloat = 2, spacing: CGFloat = 2) {
        self.level = level
        self.tint = tint
        self.barCount = barCount
        self.barWidth = barWidth
        self.spacing = spacing
        self._buffer = State(initialValue: Array(repeating: 0, count: barCount))
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: spacing) {
                ForEach(0..<buffer.count, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(fillStyle)
                        .frame(width: barWidth, height: barHeight(at: index, maxHeight: geo.size.height))
                        .frame(height: geo.size.height, alignment: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .drawingGroup()
        }
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            advance()
        }
    }

    private var fillStyle: LinearGradient {
        LinearGradient(
            colors: [
                tint.opacity(0.95),
                tint.opacity(0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func advance() {
        var next = buffer
        next.removeFirst()

        let clamped = CGFloat(max(0, min(1, level)))
        let curved = pow(clamped, 0.45)
        let last = next.last ?? 0
        let attack: CGFloat = 0.55
        let release: CGFloat = 0.12
        let rate = curved > last ? attack : release
        next.append(last + (curved - last) * rate)

        buffer = next
    }

    private func barHeight(at index: Int, maxHeight: CGFloat) -> CGFloat {
        let value = buffer[index]
        let t = CGFloat(index) / CGFloat(max(1, barCount - 1))
        let edge = 0.55 + 0.45 * sin(t * .pi)
        let minHeight: CGFloat = 3
        let scaled = minHeight + (maxHeight - minHeight) * value * edge
        return max(minHeight, scaled)
    }
}
