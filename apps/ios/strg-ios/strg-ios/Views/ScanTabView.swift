import SwiftUI
import PhotosUI

// MARK: - Scan flow state

private enum ScanFlow {
    case camera
    case processing
    case results(PredictionResponse)
    case edit(PredictionResponse)   // entries being corrected
}

// MARK: - Scan tab view

struct ScanTabView: View {
    @Binding var showsTabBar: Bool
    @Environment(StrgAPIClient.self) private var apiClient
    @Environment(SessionStore.self) private var sessionStore

    @State private var camera = CameraController()
    @State private var flow: ScanFlow = .camera
    @State private var errorMessage: String?
    @State private var currentSessionId: String?
    // Fallback photo picker (simulator / no camera)
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            switch flow {
            case .camera:
                scanScreen
                    .transition(.opacity)
            case .processing:
                processingScreen
                    .transition(.opacity)
            case .results(let response):
                resultsScreen(response)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .edit(let response):
                EditView(
                    entries: response.entries,
                    title: "EDIT WORKOUT",
                    onSave: { updated in
                        let patched = PredictionResponse(
                            entries: updated,
                            latencyS: response.latencyS,
                            entryCount: updated.count
                        )
                        if let sid = currentSessionId {
                            sessionStore.update(id: sid, entries: updated)
                        }
                        withAnimation(.easeInOut(duration: 0.28)) { flow = .results(patched) }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.28)) { flow = .results(response) }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: flowKey)
        .onChange(of: flowKey) { updateTabBar() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await analyzePickerItem(item) }
        }
        .task { await camera.setup() }
        .onDisappear { camera.stop() }
        .ignoresSafeArea()
    }

    // Flow key for animation value (must be Equatable)
    private var flowKey: Int {
        switch flow {
        case .camera: return 0
        case .processing: return 1
        case .results: return 2
        case .edit: return 3
        }
    }

    private func updateTabBar() {
        let show: Bool
        switch flow {
        case .camera: show = true
        default: show = false
        }
        withAnimation(.easeInOut(duration: 0.22)) { showsTabBar = show }
    }

    // MARK: - Scan screen

    private var scanScreen: some View {
        ZStack {
            // Camera preview or dark fallback
            if camera.isReady {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color(red: 0.024, green: 0.024, blue: 0.024)
                    .ignoresSafeArea()
            }

            // Vignette
            RadialGradient(
                colors: [.clear, .black.opacity(0.65)],
                center: .center, startRadius: 90, endRadius: 380
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Text("STRG")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                        .tracking(4)
                    Spacer()
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        .overlay(
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.6))
                        )
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)

                // Detection hint badge
                detectionBadge
                    .padding(.top, 8)

                Spacer()

                // Error
                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                }

                // Shutter / picker
                shutterZone
                    .padding(.bottom, 96) // clears tab bar
            }

            // OCR overlay (always drawn to keep consistent visual even before camera starts)
            ViewfinderOverlay()
                .allowsHitTesting(false)
                .ignoresSafeArea()

            // Permission denied state
            if camera.permissionDenied {
                cameraUnavailableOverlay
            }
        }
        .preferredColorScheme(.dark)
    }

    private var detectionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.strgAccent)
                .frame(width: 6, height: 6)
                .shadow(color: Color.strgAccent, radius: 4)
            Text("PAGE DETECTED · HOLD STEADY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .tracking(2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
                .background(Capsule().fill(.ultraThinMaterial).opacity(0.5))
        )
    }

    private var shutterZone: some View {
        VStack(spacing: 12) {
            if camera.isReady {
                // Real shutter
                Button { handleCapture() } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.85), lineWidth: 3)
                            .frame(width: 78, height: 78)
                        Circle()
                            .fill(Color.strgAccent)
                            .frame(width: 62, height: 62)
                            .shadow(color: Color.strgAccent.opacity(0.6), radius: 20)
                    }
                }
                .buttonStyle(.plain)
            } else {
                // Photo picker fallback
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.85), lineWidth: 3)
                            .frame(width: 78, height: 78)
                        Circle()
                            .fill(Color.strgAccent)
                            .frame(width: 62, height: 62)
                            .shadow(color: Color.strgAccent.opacity(0.6), radius: 20)
                        Image(systemName: "photo.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            Text("CAPTURE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2.5)
        }
    }

    private var cameraUnavailableOverlay: some View {
        VStack(spacing: 16) {
            Text("CAMERA ACCESS NEEDED")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .tracking(2)
            Text("Enable camera access in Settings,\nor pick a photo from your library.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("PICK PHOTO")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.strgAccent)
                    .tracking(2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.strgAccent.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.strgAccent.opacity(0.3), lineWidth: 0.5))
            }
        }
        .padding(40)
        .glassCard(radius: 24)
        .padding(.horizontal, 40)
    }

    // MARK: - Processing screen

    private var processingScreen: some View {
        ZStack {
            Color.strgBg.opacity(0.65)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // Silhouette
            VStack {
                Text("STRG")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(4)
                    .padding(.top, 64)
                Spacer()
            }

            // Spinner panel
            VStack(spacing: 22) {
                SpinnerView()
                VStack(spacing: 4) {
                    Text("READING")
                    Text("WORKOUT")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(2.5)
            }
            .padding(36)
            .glassCard(radius: 28)
        }
        .ignoresSafeArea()
    }

    // MARK: - Results screen

    private func resultsScreen(_ response: PredictionResponse) -> some View {
        ZStack {
            StrgBackground()

            VStack(spacing: 0) {
                // Header
                StrgHeader(trailing: AnyView(
                    HStack(spacing: 5) {
                        Text(String(format: "%.1fs", response.latencyS))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                        Circle()
                            .fill(Color.strgAccent)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.strgAccent, radius: 4)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                ))
                .padding(.top, 56)

                // Section meta
                HStack {
                    Text("WORKOUT EXTRACTED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                        .tracking(2.5)
                    Spacer()
                    Text("\(response.entryCount) EXER")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.strgAccent.opacity(0.9))
                        .tracking(2)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)

                // Cards
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(response.entries.enumerated()), id: \.offset) { idx, entry in
                            EntryCard(entry: entry, index: idx)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                }

                // Action buttons
                VStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) { flow = .edit(response) }
                    } label: {
                        Text("EDIT WORKOUT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.05))
                            .clipShape(.rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            flow = .camera
                        }
                    } label: {
                        Text("SCAN ANOTHER")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                            .tracking(2.5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.strgAccent)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(LinearGradient(
                                                colors: [.white.opacity(0.28), .clear],
                                                startPoint: .top, endPoint: .center
                                            ))
                                    )
                            )
                            .shadow(color: Color.strgAccent.opacity(0.45), radius: 22, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

    private func handleCapture() {
        Task { @MainActor in
            withAnimation { flow = .processing }
            do {
                let image = try await camera.capturePhoto()
                let response = try await apiClient.predict(image: image)
                let session = WorkoutSession(entries: response.entries)
                sessionStore.add(session)
                currentSessionId = session.id
                withAnimation { flow = .results(response) }
            } catch {
                withAnimation { flow = .camera }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func analyzePickerItem(_ item: PhotosPickerItem) async {
        await MainActor.run { withAnimation { flow = .processing }; errorMessage = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw URLError(.badServerResponse)
            }
            let response = try await apiClient.predict(image: image)
            let session = WorkoutSession(entries: response.entries)
            await MainActor.run {
                sessionStore.add(session)
                currentSessionId = session.id
                withAnimation { flow = .results(response) }
            }
        } catch {
            await MainActor.run {
                withAnimation { flow = .camera }
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Spinner

private struct SpinnerView: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2.5)
                .frame(width: 64, height: 64)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.strgAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
        }
        .onAppear { spinning = true }
    }
}

// MARK: - Viewfinder overlay

private struct ViewfinderOverlay: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let frameTop: CGFloat = 150
            let frameBottom: CGFloat = H - 250
            let frameH = frameBottom - frameTop
            let frameLeft: CGFloat = 36
            let frameRight: CGFloat = W - 36

            ZStack {
                // Corner brackets
                Group {
                    CornerBracket(v: .top,    h: .left)
                        .position(x: frameLeft + 13,  y: frameTop + 13)
                    CornerBracket(v: .top,    h: .right)
                        .position(x: frameRight - 13, y: frameTop + 13)
                    CornerBracket(v: .bottom, h: .left)
                        .position(x: frameLeft + 13,  y: frameBottom - 13)
                    CornerBracket(v: .bottom, h: .right)
                        .position(x: frameRight - 13, y: frameBottom - 13)
                }
                .opacity(phase ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: phase)

                // Sweep line
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.strgAccent, .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: frameRight - frameLeft - 12, height: 2)
                    .shadow(color: Color.strgAccent, radius: 6)
                    .position(
                        x: (frameLeft + frameRight) / 2,
                        y: frameTop + (phase ? frameH - 10 : 10)
                    )
                    .animation(
                        .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}

private enum VEdge { case top, bottom }
private enum HEdge { case left, right }

private struct CornerBracket: View {
    let v: VEdge
    let h: HEdge

    var body: some View {
        Canvas { ctx, size in
            let bw: CGFloat = 2.5
            let r: CGFloat  = 6
            let L: CGFloat  = 26

            var path = Path()
            // vertical arm
            let startY: CGFloat = v == .top ? -L / 2 : L / 2
            let endY:   CGFloat = v == .top ? r - bw / 2 : -(r - bw / 2)
            path.move(to: CGPoint(x: 0, y: startY))
            path.addLine(to: CGPoint(x: 0, y: endY))
            // horizontal arm
            let startX: CGFloat = h == .left ? -L / 2 : L / 2
            let endX:   CGFloat = h == .left ? r - bw / 2 : -(r - bw / 2)
            path.move(to: CGPoint(x: startX, y: 0))
            path.addLine(to: CGPoint(x: endX, y: 0))

            ctx.stroke(
                path,
                with: .color(Color.strgAccent),
                style: StrokeStyle(lineWidth: bw, lineCap: .round)
            )
        }
        .frame(width: 26, height: 26)
    }
}
