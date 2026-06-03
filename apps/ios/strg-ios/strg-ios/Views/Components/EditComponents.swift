import SwiftUI

// MARK: - Stepper control (sets/reps)

/// Compact stepper: [−] value [+] — used in EditView for sets & reps.
struct StepperControl: View {
    @Binding var value: Int
    var min: Int = 0
    var step: Int = 1

    var body: some View {
        HStack(spacing: 10) {
            stepperBtn("−", disabled: value <= min) {
                value = Swift.max(min, value - step)
            }
            Text("\(value)")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 30)
            stepperBtn("+") { value += step }
        }
    }

    private func stepperBtn(
        _ label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.2) : .white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Weight stepper button

/// Styled stepper button for weight adjustment.
struct WeightBtn: View {
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.2) : .white)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
