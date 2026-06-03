import SwiftUI

// MARK: - Viewfinder overlay (OCR brackets + sweep line)

/// Animated OCR viewfinder: four corner brackets + sweeping accent scan line.
/// Drawn over the camera preview.
struct ViewfinderOverlay: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let frameTop: CGFloat = 150
            let frameBottom: CGFloat = geo.size.height - 250
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
                .animation(
                    .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                    value: phase
                )

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

// MARK: - Corner bracket

enum VEdge { case top, bottom }
enum HEdge { case left, right }

struct CornerBracket: View {
    let v: VEdge
    let h: HEdge

    var body: some View {
        Canvas { ctx, size in
            let bw: CGFloat = 2.5
            let r: CGFloat  = 6
            let L: CGFloat  = 26

            var path = Path()
            // Vertical arm
            let startY: CGFloat = v == .top ? -L / 2 : L / 2
            let endY:   CGFloat = v == .top ? r - bw / 2 : -(r - bw / 2)
            path.move(to: CGPoint(x: 0, y: startY))
            path.addLine(to: CGPoint(x: 0, y: endY))
            // Horizontal arm
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
