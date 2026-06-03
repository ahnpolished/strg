import SwiftUI

// MARK: - Shared background

/// Near-black canvas (#080808) with radial accent bloom + faint grain.
/// Gives glass surfaces something to pick up — essential for glassmorphism.
struct StrgBackground: View {
    var body: some View {
        ZStack {
            Color.strgBg.ignoresSafeArea()

            // Top accent bloom
            RadialGradient(
                colors: [Color.strgAccent.opacity(0.09), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()

            // Hairline grain so glass reads depth
            Color.white.opacity(0.018)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

// MARK: - STRG wordmark header

struct StrgHeader: View {
    var trailing: AnyView?
    var body: some View {
        HStack {
            Text("STRG")
                .font(.strgWordmark)
                .foregroundStyle(.white)
                .wordmarkTracking()
            Spacer()
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }
}

// MARK: - Latency badge pill

struct LatencyBadge: View {
    let seconds: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(String(format: "%.1fs", seconds))
                .font(.strgStatus)
                .foregroundStyle(.white.opacity(0.55))
            Circle()
                .fill(Color.strgAccent)
                .frame(width: 6, height: 6)
                .shadow(color: Color.strgAccent, radius: 4)
        }
        .glassPill()
    }
}
