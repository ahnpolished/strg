import SwiftUI
import PhotosUI

// MARK: - Design tokens

private extension Color {
    static let strgBg     = Color(red: 0.031, green: 0.031, blue: 0.031) // #080808
    static let strgAccent = Color(red: 1.0,   green: 0.294, blue: 0.0)   // #FF4B00
}

// MARK: - Glass card modifier

private struct GlassCard: ViewModifier {
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

private extension View {
    func glassCard(radius: CGFloat = 20) -> some View { modifier(GlassCard(radius: radius)) }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(StrgAPIClient.self) private var apiClient
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var result: PredictionResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var capturePulse = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header.padding(.top, 8)
                if let r = result {
                    ResultsView(response: r, isLoading: isLoading, onScanAnother: {
                        result = nil
                        errorMessage = nil
                    }, selectedPhoto: $selectedPhoto)
                } else {
                    captureView
                }
            }
            if isLoading { loadingOverlay }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await analyze(item) }
        }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            Color.strgBg.ignoresSafeArea()
            RadialGradient(
                colors: [Color.strgAccent.opacity(0.08), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("STRG")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
                .tracking(4)
            Spacer()
            if let r = result {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green.opacity(0.85))
                        .frame(width: 6, height: 6)
                    Text(String(format: "%.1fs", r.latencyS))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(0.5)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: Capture

    private var captureView: some View {
        VStack(spacing: 0) {
            Spacer()
            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                ZStack {
                    // outer pulse ring
                    Circle()
                        .stroke(Color.strgAccent.opacity(0.35), lineWidth: 1)
                        .frame(width: 210, height: 210)
                        .scaleEffect(capturePulse ? 1.12 : 1.0)
                        .opacity(capturePulse ? 0 : 0.6)
                        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false), value: capturePulse)
                    // inner pulse ring
                    Circle()
                        .stroke(Color.strgAccent.opacity(0.2), lineWidth: 0.5)
                        .frame(width: 185, height: 185)
                        .scaleEffect(capturePulse ? 1.1 : 0.96)
                        .opacity(capturePulse ? 0 : 0.4)
                        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false).delay(0.5), value: capturePulse)
                    // glass button
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 158, height: 158)
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: Color.strgAccent.opacity(0.18), radius: 32)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 38, weight: .light))
                                .foregroundStyle(.white.opacity(0.88))
                        )
                }
            }
            .disabled(isLoading)
            .onAppear { capturePulse = true }

            Spacer().frame(height: 36)

            VStack(spacing: 7) {
                Text("SCAN WORKOUT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(3)
                Text("Tap to analyze your journal page")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.22))
            }

            Spacer()

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: Loading overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 2)
                        .frame(width: 60, height: 60)
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(Color.strgAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(isLoading ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isLoading)
                }
                Text("READING WORKOUT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(2.5)
            }
            .padding(36)
            .glassCard(radius: 28)
        }
    }

    // MARK: Analysis

    private func analyze(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        result = nil
        defer { isLoading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Failed to load photo"
                return
            }
            result = try await apiClient.predict(image: image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Results view

private struct ResultsView: View {
    let response: PredictionResponse
    let isLoading: Bool
    let onScanAnother: () -> Void
    @Binding var selectedPhoto: PhotosPickerItem?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Section meta
            HStack {
                Text("WORKOUT EXTRACTED")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(2.5)
                Spacer()
                Text("\(response.entryCount) EXERCISES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.strgAccent.opacity(0.85))
                    .tracking(1.5)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            // Entry cards
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(Array(response.entries.enumerated()), id: \.offset) { idx, entry in
                        EntryCard(entry: entry)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 36)
                            .animation(
                                .spring(response: 0.52, dampingFraction: 0.78)
                                    .delay(Double(idx) * 0.08),
                                value: appeared
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
        }
        .overlay(alignment: .bottom) { scanAnotherButton }
        .onAppear {
            appeared = false
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000)
                appeared = true
            }
        }
    }

    private var scanAnotherButton: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("SCAN ANOTHER")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.strgAccent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.18), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
            )
            .shadow(color: Color.strgAccent.opacity(0.45), radius: 22, x: 0, y: 4)
        }
        .disabled(isLoading)
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .background(
            LinearGradient(
                colors: [.clear, Color.strgBg.opacity(0.96)],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.7)
            )
            .ignoresSafeArea()
        )
    }
}

// MARK: - Entry card

struct EntryCard: View {
    let entry: WorkoutEntry

    private var weightDisplay: String? {
        if let kg  = entry.weightKg  { return String(format: "%.0f KG",  kg)  }
        if let lbs = entry.weightLbs { return String(format: "%.0f LBS", lbs) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name + date row
            HStack(alignment: .firstTextBaseline) {
                Text(entry.exercise.uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if let date = entry.date {
                    Text(date)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.28))
                        .tracking(0.3)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            // Numbers row
            HStack(alignment: .bottom) {
                // Sets × Reps
                VStack(alignment: .leading, spacing: 4) {
                    Text("SETS × REPS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(1.5)
                    Text("\(entry.sets)×\(entry.reps)")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                // Weight
                VStack(alignment: .trailing, spacing: 4) {
                    Text("WEIGHT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
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

            // Notes
            if let notes = entry.notes, !notes.isEmpty {
                Text("\" \(notes) \"")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(2)
            }
        }
        .padding(20)
        .glassCard(radius: 20)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(StrgAPIClient())
}
