import SwiftUI

// MARK: - Processing spinner

/// Arc spinner for the "READING WORKOUT" processing panel.
/// Accent arc rotates continuously on a subtle track.
struct SpinnerView: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2.5)
                .frame(width: 64, height: 64)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    Color.strgAccent,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: spinning
                )
        }
        .onAppear { spinning = true }
    }
}
