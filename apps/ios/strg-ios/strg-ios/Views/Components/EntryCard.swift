import SwiftUI

// MARK: - EntryCard (spec variant — matches design default)

struct EntryCard: View {
    let entry: WorkoutEntry
    var variant: CardVariant = .spec
    var index: Int = 0
    var animate: Bool = true
    @State private var appeared = false

    enum CardVariant { case spec, hero, compact }

    var body: some View {
        Group {
            switch variant {
            case .compact: compactLayout
            case .hero: heroLayout
            case .spec: specLayout
            }
        }
        .glassSurface(radius: 20)
        .offset(y: animate && !appeared ? 14 : 0)
        .scaleEffect(animate && !appeared ? 0.99 : 1.0)
        .animation(
            StrgAnimation.cardEntrance.delay(Double(index) * 0.08),
            value: appeared
        )
        .onAppear { if animate { appeared = true } }
    }

    // MARK: Spec layout (default)

    private var specLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameRow
            separator
            numbersRow
            noteRow
        }
        .padding(20)
    }

    // MARK: Hero layout

    private var heroLayout: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(weightDisplay != nil ? Color.strgAccent : Color.white.opacity(0.10))
                .frame(width: 3)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.exercise.uppercased())
                        .font(.strgExerciseName)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    VStack(alignment: .leading, spacing: 4) {
                        microLabel("SETS × REPS")
                        Text("\(entry.sets)×\(entry.reps)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 10)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    microLabel("WEIGHT")
                    weightView(size: 40)
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Compact layout

    private var compactLayout: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.exercise.uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(entry.sets)×\(entry.reps)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.30))
            }
            Spacer()
            weightView(size: 26)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: Shared subviews

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.exercise.uppercased())
                .font(.strgExerciseName)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if let date = entry.date {
                Text(date)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
    }

    private var numbersRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                microLabel("SETS × REPS")
                Text("\(entry.sets)×\(entry.reps)")
                    .font(.strgBigNumber)
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                microLabel("WEIGHT")
                weightView(size: 28)
            }
        }
    }

    @ViewBuilder
    private var noteRow: some View {
        if let notes = entry.notes, !notes.isEmpty {
            Text("\" \(notes) \"")
                .font(.strgNotes)
                .foregroundStyle(.white.opacity(0.28))
                .lineLimit(2)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func weightView(size: CGFloat) -> some View {
        if let w = weightDisplay {
            Text(w)
                .font(.system(size: size, weight: .black, design: .rounded))
                .foregroundStyle(Color.strgAccent)
        } else {
            Text("—")
                .font(.system(size: size, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private func microLabel(_ text: String) -> some View {
        Text(text)
            .microLabelStyle()
    }

    private var weightDisplay: String? {
        if let kg = entry.weightKg { return String(format: "%.0f KG", kg) }
        if let lbs = entry.weightLbs { return String(format: "%.0f LBS", lbs) }
        return nil
    }
}
