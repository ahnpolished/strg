import SwiftUI

// MARK: - Onboarding shared components

/// Progress dots for the onboarding top bar.
struct ProgressDots: View {
    let total: Int
    let active: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                RoundedRectangle(cornerRadius: 999)
                    .fill(dotColor(for: i))
                    .frame(width: i == active ? 22 : 4, height: 4)
                    .animation(.easeInOut(duration: 0.3), value: active)
            }
        }
    }

    private func dotColor(for i: Int) -> Color {
        if i == active { return Color.strgAccent }
        if i < active  { return .white.opacity(0.4) }
        return .white.opacity(0.14)
    }
}

// MARK: - CTA Button

/// Primary or secondary call-to-action button matching strg's design.
struct CTAButton: View {
    let label: String
    let solid: Bool
    let action: () -> Void

    init(_ label: String, solid: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.solid = solid
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.strgCTA)
                .foregroundStyle(solid ? .white : .white.opacity(0.7))
                .tracking(2.5)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            solid
                            ? AnyShapeStyle(Color.strgAccent)
                            : AnyShapeStyle(Color.white.opacity(0.05))
                        )
                        .overlay {
                            if solid {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(LinearGradient(
                                        colors: [.white.opacity(0.28), .clear],
                                        startPoint: .top, endPoint: .center
                                    ))
                            }
                        }
                }
                .overlay {
                    if !solid {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    }
                }
                .shadow(
                    color: solid ? Color.strgAccent.opacity(0.45) : .clear,
                    radius: 22, x: 0, y: 4
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Option card (onboarding)

/// Selectable glass option card with radio checkmark, used in onboarding steps.
struct OptionCard<Content: View>: View {
    let selected: Bool
    let legend: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                content()

                HStack {
                    MicroLabel(text: legend)
                    Spacer()
                    radioIndicator
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .buttonStyle(.plain)
        .subtleGlass(radius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    selected ? Color.strgAccent.opacity(0.8) : .clear,
                    lineWidth: 1.5
                )
        }
        .overlay {
            if !selected {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, selected ? 2 : 0)
    }

    private var radioIndicator: some View {
        Circle()
            .fill(selected ? Color.strgAccent : .clear)
            .frame(width: 18, height: 18)
            .overlay {
                if !selected {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

// MARK: - Handwritten text

/// Simulates handwriting using the built-in Noteworthy font + slight rotation.
/// Used in onboarding to preview the user's custom notation format.
struct HandwrittenText: View {
    let text: String
    var size: CGFloat = 23
    var rotation: Double = -1.5
    var color: Color = Color(red: 0.925, green: 0.906, blue: 0.855)

    var body: some View {
        Text(text)
            .font(.custom("Noteworthy", size: size).weight(.bold))
            .foregroundStyle(color)
            .tracking(0.5)
            .rotationEffect(.degrees(rotation))
            .lineLimit(1)
    }
}

/// Faint ruled line — simulates notebook paper under handwriting.
struct RuledLine: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 0.47, green: 0.59, blue: 0.78).opacity(0.16))
            .frame(height: 1)
    }
}

// MARK: - Micro label

/// Standard micro label: 9.5pt semibold, tracked, uppercase.
struct MicroLabel: View {
    let text: String
    var color: Color = .white.opacity(0.32)

    var body: some View {
        Text(text)
            .microLabelStyle(color: color)
    }
}

// MARK: - ReadOut (payoff card)

struct ReadOut: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
                .tracking(1.5)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.strgAccent)
                .tracking(0.4)
        }
    }
}
