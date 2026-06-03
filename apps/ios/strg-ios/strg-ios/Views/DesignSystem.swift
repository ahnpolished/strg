import SwiftUI

// MARK: - Color tokens

extension Color {
    static let strgBg     = Color(red: 0.031, green: 0.031, blue: 0.031) // #080808
    static let strgAccent = Color(red: 1.0,   green: 0.294, blue: 0.0)   // #FF4B00
}

// MARK: - Glass card

struct GlassCardModifier: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
    }
}

extension View {
    func glassCard(radius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }
}

// MARK: - Shared background

struct StrgBackground: View {
    var body: some View {
        ZStack {
            Color.strgBg.ignoresSafeArea()
            RadialGradient(
                colors: [Color.strgAccent.opacity(0.09), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()
            // hairline dot grid — gives glass surfaces something to pick up
            Color.white.opacity(0.018)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

// MARK: - STRG wordmark header

struct StrgHeader: View {
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text("STRG")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
                .tracking(4)
            Spacer()
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }
}

// MARK: - Entry card (spec variant — matches design default)

struct EntryCard: View {
    let entry: WorkoutEntry
    var animate: Bool = true
    var index: Int = 0
    @State private var appeared = false

    private var weightDisplay: String? {
        if let kg  = entry.weightKg  { return String(format: "%.0f KG",  kg)  }
        if let lbs = entry.weightLbs { return String(format: "%.0f LBS", lbs) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name + date
            HStack(alignment: .firstTextBaseline) {
                Text(entry.exercise.uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if let date = entry.date {
                    Text(date)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.28))
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            // Numbers
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("SETS × REPS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                        .tracking(1.5)
                    Text("\(entry.sets)×\(entry.reps)")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Text("WEIGHT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                        .tracking(1.5)
                    if let w = weightDisplay {
                        Text(w)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(Color.strgAccent)
                    } else {
                        Text("—")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
            }

            if let notes = entry.notes, !notes.isEmpty {
                Text("\" \(notes) \"")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(2)
            }
        }
        .padding(20)
        .glassCard(radius: 20)
        .offset(y: animate && !appeared ? 14 : 0)
        .scaleEffect(animate && !appeared ? 0.99 : 1.0)
        .animation(
            .spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.08),
            value: appeared
        )
        .onAppear {
            if animate { appeared = true }
        }
    }
}
