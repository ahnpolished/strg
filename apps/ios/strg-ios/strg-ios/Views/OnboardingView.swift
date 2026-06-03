import SwiftUI

// MARK: - Onboarding flow

/// Onboarding calibration — six quick steps that teach strg the user's
/// handwriting shorthand. Frame it as calibration, not encouragement.
struct OnboardingView: View {
    @State private var screen: OnboardingStep = .intro
    @State private var prefs = OnboardingPreferences()
    let onComplete: (OnboardingPreferences) -> Void

    var body: some View {
        ZStack {
            StrgBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: progress dots + optional back
                topBar
                    .padding(.horizontal, 22)
                    .padding(.top, 60)

                // Body
                Group {
                    switch screen {
                    case .intro:
                        IntroBody(onNext: { screen = .order })
                    case .order:
                        NotationStep(prefs: $prefs, onNext: { screen = .separator }, onBack: { screen = .intro })
                    case .separator:
                        SeparatorStep(prefs: $prefs, onNext: { screen = .setsReps }, onBack: { screen = .order })
                    case .setsReps:
                        SetsRepsStep(prefs: $prefs, onNext: { screen = .units }, onBack: { screen = .separator })
                    case .units:
                        UnitsStep(prefs: $prefs, onNext: { screen = .ready }, onBack: { screen = .setsReps })
                    case .ready:
                        ReadyBody(prefs: prefs, onStart: { onComplete(prefs) })
                    }
                }
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.28), value: screen)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            if screen != .intro && screen != .ready {
                Button {
                    withAnimation { screen = screen.previous }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 34, height: 34)
            }

            Spacer()

            if screen.isQuestion {
                ProgressDots(total: 4, active: screen.stepIndex)
            }

            Spacer()

            Color.clear.frame(width: 34, height: 34)
        }
        .frame(height: 36)
        .padding(.bottom, 8)
    }
}

// MARK: - Step enum

private enum OnboardingStep: Equatable {
    case intro, order, separator, setsReps, units, ready

    var isQuestion: Bool {
        switch self {
        case .intro, .ready: return false
        default: return true
        }
    }

    var stepIndex: Int {
        switch self {
        case .order: return 0
        case .separator: return 1
        case .setsReps: return 2
        case .units: return 3
        default: return 0
        }
    }

    var previous: OnboardingStep {
        switch self {
        case .order: return .intro
        case .separator: return .order
        case .setsReps: return .separator
        case .units: return .setsReps
        case .ready: return .units
        case .intro: return .intro
        }
    }
}

// MARK: - Progress dots

// MARK: - CTA button

// MARK: - Micro label

// MARK: - Section title

private struct StepTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(.white)
            .tracking(0.2)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StepSubtitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.42))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}

// MARK: - Ruled handwritten text

// Highlight part of a sample with accent color
/// Faint ruled line under a block of handwritten text
// MARK: - Option card

// MARK: - 1. Intro step

private struct IntroBody: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                Text("STRG")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(.white)
                    .tracking(7)

                Text("Teach strg\nyour shorthand.")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(0.2)
                    .padding(.top, 24)

                Text("You already log your lifts your way. Four quick taps and\nstrg reads your notebook exactly as you write it.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineSpacing(4)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)

                // Handwritten preview
                HandwrittenText(
                    text: "Bench Press  135  4×8",
                    size: 28,
                    rotation: -2,
                    color: .white.opacity(0.85)
                )
                .padding(.top, 30)

                MicroLabel(text: "↑ strg learns to read this", color: .white.opacity(0.22))
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)

            Spacer()

            CTAButton("Begin", action: onNext)
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
        }
    }
}

// MARK: - Reusable question step layout

private struct QuestionStep<Option: Identifiable, BodyView: View>: View {
    let title: String
    let subtitle: String
    let options: [Option]
    let selectedId: Option.ID
    let onSelect: (Option.ID) -> Void
    let onNext: () -> Void
    let onBack: () -> Void
    @ViewBuilder let render: (Option) -> (legend: String, body: @MainActor () -> BodyView)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StepTitle(text: title)
                StepSubtitle(text: subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { _, opt in
                        let rendered = render(opt)
                        OptionCard(
                            selected: selectedId == opt.id,
                            legend: rendered.legend,
                            action: { onSelect(opt.id) }
                        ) {
                            rendered.body()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }

            CTAButton("Continue", action: onNext)
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
        }
    }
}

// MARK: - 2. Notation order step

private struct NotationOrderOption: Identifiable {
    let id: String
    let tokens: [String]
    let legend: String
}

private struct NotationStep: View {
    @Binding var prefs: OnboardingPreferences
    let onNext: () -> Void
    let onBack: () -> Void

    private static let options: [NotationOrderOption] = [
        .init(id: "nwrn", tokens: ["name","weight","reps","note"], legend: "NAME · WEIGHT · REPS · NOTE"),
        .init(id: "nsw",  tokens: ["name","sr","weight"],     legend: "NAME · SETS×REPS · WEIGHT"),
        .init(id: "nws",  tokens: ["name","weight","sr"],     legend: "NAME · WEIGHT · SETS×REPS"),
        .init(id: "nrw",  tokens: ["name","reps","weight"],   legend: "NAME · REPS · WEIGHT"),
    ]

    var body: some View {
        QuestionStep(
            title: "How do you write a set?",
            subtitle: "Pick the order that matches your notebook.",
            options: Self.options,
            selectedId: prefs.order,
            onSelect: { prefs.order = $0 },
            onNext: onNext,
            onBack: onBack
        ) { opt in
            let sample = composeSample(order: opt.id, prefs: prefs)
            return (
                legend: opt.legend,
                body: {
                    VStack(spacing: 0) {
                        HandwrittenText(text: sample, size: 21)
                            .padding(.top, 14)
                            .padding(.horizontal, 18)
                        RuledLine()
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                    }
                }
            )
        }
    }
}

// MARK: - 3. Separator step

private struct SeparatorOption: Identifiable {
    let id: String
    let glyph: String
    let label: String
}

private struct SeparatorStep: View {
    @Binding var prefs: OnboardingPreferences
    let onNext: () -> Void
    let onBack: () -> Void

    private static let options: [SeparatorOption] = [
        .init(id: "space", glyph: " ",  label: "SPACE"),
        .init(id: "pipe",  glyph: "|",  label: "PIPE"),
        .init(id: "dash",  glyph: "–",  label: "DASH"),
        .init(id: "slash", glyph: "/",  label: "SLASH"),
    ]

    var body: some View {
        QuestionStep(
            title: "What divides your values?",
            subtitle: "The mark between each number on the page.",
            options: Self.options,
            selectedId: prefs.separator,
            onSelect: { prefs.separator = $0 },
            onNext: onNext,
            onBack: onBack
        ) { opt in
            return (
                legend: opt.label,
                body: {
                    VStack(spacing: 0) {
                        highlightedSeparator(glyph: opt.glyph, unit: prefs.unit == "KG" ? "60" : "135")
                            .padding(.top, 14)
                            .padding(.horizontal, 18)
                        RuledLine()
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func highlightedSeparator(glyph: String, unit: String) -> some View {
        let parts = ["Bench", unit, "4×8"]
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Text(glyph == " " ? "   " : "  \(glyph)  ")
                        .foregroundStyle(Color.strgAccent)
                }
                Text(part)
            }
        }
        .font(.custom("Noteworthy", size: 21).weight(.bold))
        .foregroundStyle(Color(red: 0.925, green: 0.906, blue: 0.855))
        .tracking(0.5)
        .rotationEffect(.degrees(-1.4))
        .lineLimit(1)
    }
}

// MARK: - 4. Sets × Reps step

private struct SROption: Identifiable {
    let id: String
    let sr: String
    let legend: String
}

private struct SetsRepsStep: View {
    @Binding var prefs: OnboardingPreferences
    let onNext: () -> Void
    let onBack: () -> Void

    private static let options: [SROption] = [
        .init(id: "x",    sr: "4×8",     legend: "SETS × REPS"),
        .init(id: "lowx", sr: "4x8",     legend: "SETS x REPS"),
        .init(id: "list", sr: "8·8·8·8", legend: "REPS PER SET"),
        .init(id: "sets", sr: "3 × 5",   legend: "SETS × REPS"),
    ]

    var body: some View {
        QuestionStep(
            title: "How do you note sets & reps?",
            subtitle: "So strg counts your work right.",
            options: Self.options,
            selectedId: prefs.setsReps,
            onSelect: { prefs.setsReps = $0 },
            onNext: onNext,
            onBack: onBack
        ) { opt in
            return (
                legend: opt.legend,
                body: {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Bench  ")
                            Text(opt.sr)
                                .foregroundStyle(Color.strgAccent)
                            Text("  135")
                        }
                        .font(.custom("Noteworthy", size: 21).weight(.bold))
                        .foregroundStyle(Color(red: 0.925, green: 0.906, blue: 0.855))
                        .tracking(0.5)
                        .rotationEffect(.degrees(-1))
                        .lineLimit(1)
                        .padding(.top, 14)
                        .padding(.horizontal, 18)
                        RuledLine()
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                    }
                }
            )
        }
    }
}

// MARK: - 5. Units step

private struct UnitOption: Identifiable {
    let id: String
    let sample: String
}

private struct UnitsStep: View {
    @Binding var prefs: OnboardingPreferences
    let onNext: () -> Void
    let onBack: () -> Void

    private static let options: [UnitOption] = [
        .init(id: "LBS", sample: "135 lb"),
        .init(id: "KG",  sample: "60 kg"),
    ]

    var body: some View {
        QuestionStep(
            title: "Pounds or kilos?",
            subtitle: "The weight you load on the bar.",
            options: Self.options,
            selectedId: prefs.unit,
            onSelect: { prefs.unit = $0 },
            onNext: onNext,
            onBack: onBack
        ) { opt in
            let label = opt.id == "LBS" ? "POUNDS" : "KILOGRAMS"
            return (
                legend: label,
                body: {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Bench  ")
                            Text(opt.sample)
                                .foregroundStyle(Color.strgAccent)
                            Text("  4×8")
                        }
                        .font(.custom("Noteworthy", size: 21).weight(.bold))
                        .foregroundStyle(Color(red: 0.925, green: 0.906, blue: 0.855))
                        .tracking(0.5)
                        .rotationEffect(.degrees(-1))
                        .lineLimit(1)
                        .padding(.top, 14)
                        .padding(.horizontal, 18)
                        RuledLine()
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                    }
                }
            )
        }
    }
}

// MARK: - 6. Ready (payoff)

private struct ReadyBody: View {
    let prefs: OnboardingPreferences
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                MicroLabel(text: "CALIBRATED", color: Color.strgAccent)

                Text("strg speaks\nyour hand now.")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(0.2)
                    .padding(.top, 12)

                Text("Write a set like this and strg pulls it clean — every time.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineSpacing(3)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)

                // Payoff card: their exact format on a ruled notebook line
                PayoffCard(prefs: prefs)
                    .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)

            Spacer()

            CTAButton("Start lifting", action: {
                prefs.save()
                OnboardingPreferences.markCompleted()
                onStart()
            })
            .padding(.horizontal, 22)
            .padding(.bottom, 34)
        }
    }
}

// MARK: - Payoff card

private struct PayoffCard: View {
    let prefs: OnboardingPreferences

    private var composedLine: String {
        composeSample(order: prefs.order, prefs: prefs)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handwritten line on ruled background
            VStack(spacing: 0) {
                HandwrittenText(
                    text: composedLine,
                    size: 24,
                    rotation: -1.5,
                    color: Color(red: 0.925, green: 0.906, blue: 0.855)
                )
                .padding(.top, 18)
                .padding(.horizontal, 20)
                RuledLine()
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            // Readout row
            HStack(spacing: 18) {
                ReadOut(label: "UNITS", value: prefs.unit)
                ReadOut(label: "FORMAT", value: formatLabel)
                ReadOut(label: "DIVIDER", value: dividerLabel)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.035))
        )
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
    }

    private var formatLabel: String {
        let n: Int = {
            switch prefs.order {
            case "nsw", "nws": return 3
            case "nrw": return 3
            default: return 4
            }
        }()
        return "\(n) fields"
    }

    private var dividerLabel: String {
        switch prefs.separator {
        case "space": return "SPACE"
        case "pipe":  return "PIPE"
        case "dash":  return "DASH"
        case "slash": return "SLASH"
        default: return "PIPE"
        }
    }
}

// MARK: - Sample composer (shared logic)

private func composeSample(order: String, prefs: OnboardingPreferences) -> String {
    let sr = srNotation(for: prefs.setsReps)
    let unit = prefs.unit == "KG" ? "60" : "135"

    let vals: [String: String] = [
        "name":   "Bench",
        "weight": unit,
        "sr":     sr,
        "reps":   "8",
        "note":   "PR",
    ]

    let tokens: [String] = {
        switch order {
        case "nsw":  return ["name", "sr", "weight"]
        case "nws":  return ["name", "weight", "sr"]
        case "nrw":  return ["name", "reps", "weight"]
        default:     return ["name", "weight", "reps", "note"]
        }
    }()

    let sep = separatorGlyph(for: prefs.separator)
    let joined: String = {
        switch prefs.separator {
        case "space": return tokens.compactMap { vals[$0] }.joined(separator: "   ")
        default:      return tokens.compactMap { vals[$0] }.joined(separator: " \(sep) ")
        }
    }()
    return joined
}

private func srNotation(for id: String) -> String {
    switch id {
    case "lowx": return "4x8"
    case "list": return "8·8·8·8"
    case "sets": return "3 × 5"
    default:     return "4×8"
    }
}

private func separatorGlyph(for id: String) -> String {
    switch id {
    case "pipe":  return "|"
    case "dash":  return "–"
    case "slash": return "/"
    default:      return " "
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: { _ in })
            .preferredColorScheme(.dark)
    }
}
#endif
