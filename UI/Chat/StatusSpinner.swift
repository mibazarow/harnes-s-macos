import SwiftUI

/// The copper spinner for service lines.
///
/// `ProgressView` on macOS ignores `.tint` and its size fights the line height, so the
/// arc is drawn here: `AppFont.statusSize` points across, one line high. The size is in
/// points and does not follow the transcript size.
///
/// With Reduce Motion the ring does not rotate: it pulses its opacity instead.
struct StatusSpinner: View {
    var size: CGFloat = AppFont.statusSize

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    @State private var dimmed = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                theme.accent,
                style: StrokeStyle(lineWidth: max(size / 7, 1.5), lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .opacity(dimmed ? 0.4 : 1)
            .accessibilityHidden(true)
            .onAppear(perform: start)
            .onDisappear {
                angle = 0
                dimmed = false
            }
    }

    private func start() {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        } else {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}
