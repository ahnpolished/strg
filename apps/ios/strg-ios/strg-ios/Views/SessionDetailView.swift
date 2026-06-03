import SwiftUI

struct SessionDetailView: View {
    let session: WorkoutSession
    let onBack: () -> Void
    let onEdit: (([WorkoutEntry]) -> Void)?

    @State private var showingEdit = false

    var body: some View {
        if showingEdit {
            EditView(
                entries: session.entries,
                title: "EDIT SESSION",
                onSave: { updated in
                    onEdit?(updated)
                    showingEdit = false
                },
                onCancel: { showingEdit = false }
            )
        } else {
            detailBody
        }
    }

    private var detailBody: some View {
        let f = session.dateParts
        return ZStack {
            StrgBackground()
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(f.month) \(f.day) · \(session.label)")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("\(f.weekday) · \(session.entries.count) EXERCISES")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .tracking(0.5)
                    }

                    Spacer()

                    if onEdit != nil {
                        Button("EDIT") { showingEdit = true }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(1.5)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 56)
                .padding(.bottom, 6)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(session.entries.enumerated()), id: \.offset) { idx, entry in
                            EntryCard(entry: entryWithDate(entry, f.short), index: idx)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func entryWithDate(_ entry: WorkoutEntry, _ date: String) -> WorkoutEntry {
        WorkoutEntry(
            date: date, exercise: entry.exercise,
            sets: entry.sets, reps: entry.reps,
            weightKg: entry.weightKg, weightLbs: entry.weightLbs,
            notes: entry.notes
        )
    }
}
