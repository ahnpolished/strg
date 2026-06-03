import SwiftUI

// MARK: - Mutable edit row (bridges from/to WorkoutEntry)

struct EditRow: Identifiable {
    let id = UUID()
    var exercise: String
    var sets: Int
    var reps: Int
    var weightLbs: Double?   // nil = bodyweight
    var notes: String

    init(_ entry: WorkoutEntry) {
        exercise  = entry.exercise
        sets      = entry.sets
        reps      = entry.reps
        // Prefer stored lbs; fall back to converting kg
        weightLbs = entry.weightLbs ?? entry.weightKg.map { $0 / 0.453592 }
        notes     = entry.notes ?? ""
    }

    var toEntry: WorkoutEntry {
        WorkoutEntry(
            date: nil, exercise: exercise.uppercased(),
            sets: sets, reps: reps,
            weightKg: nil, weightLbs: weightLbs,
            notes: notes.isEmpty ? nil : notes
        )
    }
}

// MARK: - Edit view

struct EditView: View {
    let title: String
    let onSave: ([WorkoutEntry]) -> Void
    let onCancel: () -> Void

    @State private var rows: [EditRow]

    init(entries: [WorkoutEntry], title: String = "EDIT WORKOUT",
         onSave: @escaping ([WorkoutEntry]) -> Void, onCancel: @escaping () -> Void) {
        self.title    = title
        self.onSave   = onSave
        self.onCancel = onCancel
        _rows = State(initialValue: entries.map(EditRow.init))
    }

    var body: some View {
        ZStack {
            StrgBackground()
            VStack(spacing: 0) {
                // Top bar
                topBar
                    .padding(.top, 56)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach($rows) { $row in
                            EditRowCard(row: $row, onRemove: { removeRow(id: row.id) })
                        }
                        addButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .tracking(2.5)
            Spacer()
            Button("Save") { onSave(rows.map(\.toEntry)) }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.strgAccent)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    // MARK: Add button

    private var addButton: some View {
        Button {
            rows.append(EditRow(WorkoutEntry(
                date: nil, exercise: "NEW EXERCISE",
                sets: 3, reps: 8, weightKg: nil, weightLbs: 45, notes: nil
            )))
        } label: {
            Text("+ ADD EXERCISE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5]))
                )
        }
        .buttonStyle(.plain)
    }

    private func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
    }
}

// MARK: - Per-exercise edit card

private struct EditRowCard: View {
    @Binding var row: EditRow
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Name field + remove button
            HStack(spacing: 10) {
                TextField("Exercise", text: $row.exercise)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.04))
                        .clipShape(.rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            // Sets + Reps steppers
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("SETS")
                    StepperControl(value: $row.sets, min: 1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("REPS")
                    StepperControl(value: $row.reps, min: 1)
                }
            }

            // Weight row
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("WEIGHT · LBS")
                HStack(spacing: 10) {
                    // Minus
                    stepperBtn("−", disabled: row.weightLbs != nil && row.weightLbs! <= 0) {
                        row.weightLbs = max(0, (row.weightLbs ?? 0) - 5)
                    }
                    // Input
                    TextField("—", value: $row.weightLbs, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 19, weight: .black, design: .rounded))
                        .foregroundStyle(Color.strgAccent)
                        .multilineTextAlignment(.center)
                        .frame(width: 92)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04))
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    // Plus
                    stepperBtn("+") {
                        row.weightLbs = (row.weightLbs ?? 0) + 5
                    }
                    if row.weightLbs == nil {
                        Text("bodyweight")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }

            // Memo
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("MEMO")
                TextField("Add a note", text: $row.notes)
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassCard(radius: 20)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.3))
            .tracking(1.5)
    }

    private func stepperBtn(_ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.2) : .white)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Stepper control (sets/reps)

private struct StepperControl: View {
    @Binding var value: Int
    var min: Int = 0
    var step: Int = 1

    var body: some View {
        HStack(spacing: 10) {
            btn("−", disabled: value <= min) { value = Swift.max(min, value - step) }
            Text("\(value)")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 30)
            btn("+") { value += step }
        }
    }

    private func btn(_ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.2) : .white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
