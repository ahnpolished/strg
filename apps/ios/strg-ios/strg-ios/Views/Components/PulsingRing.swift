import SwiftUI

// MARK: - Pulsing concentric rings

/// Two concentric accent rings that pulse outward on an infinite loop.
/// Matches the Capture (idle) screen design — the breathing glow around
/// the scan button.
///
/// Uses iOS 17+ `phaseAnimator` when available for declarative animation
/// lifecycle; falls back to imperative state + `.animation()` on iOS 16.
struct PulsingRing: View {
    let delay: Double

    var body: some View {
        if #available(iOS 17.0, *) {
            ringView
                .phaseAnimator(PulsePhase.allCases, trigger: UUID()) { view, phase in
                    view
                        .scaleEffect(phase.scale)
                        .opacity(phase.opacity)
                } animation: { phase in
                    .easeInOut(duration: 2.5)
                }
        } else {
            LegacyPulsingRing(delay: delay)
        }
    }

    private var ringView: some View {
        Circle()
            .stroke(Color.strgAccent, lineWidth: 1.5)
            .frame(width: 160, height: 160)
    }
}

// MARK: - Pulse phases (iOS 17+)

private struct PulsePhase: Hashable {
    let scale: CGFloat
    let opacity: CGFloat

    static let start = PulsePhase(scale: 1.0, opacity: 0.30)
    static let peak  = PulsePhase(scale: 1.45, opacity: 0)

    static let allCases: [PulsePhase] = [.start, .peak, .start]
}

// MARK: - iOS 16/17 fallback

private struct LegacyPulsingRing: View {
    let delay: Double
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(Color.strgAccent, lineWidth: 1.5)
            .frame(width: 160, height: 160)
            .scaleEffect(animating ? 1.45 : 1.0)
            .opacity(animating ? 0 : 0.3)
            .animation(
                .easeInOut(duration: 2.5)
                    .delay(delay)
                    .repeatForever(autoreverses: false),
                value: animating
            )
            .onAppear { animating = true }
    }
}
