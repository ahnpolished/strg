import SwiftUI

// MARK: - Viewfinder glyph

/// The camera/viewfinder icon rendered inside the capture circle.
struct ViewfinderGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            let bw: CGFloat = 2.4

            // Corner brackets
            var border = Path()
            corner(&border, cx: 0, cy: 0, dx: s * 0.38, dy: s * 0.38)
            corner(&border, cx: s, cy: 0, dx: -s * 0.38, dy: s * 0.38)
            corner(&border, cx: 0, cy: s, dx: s * 0.38, dy: -s * 0.38)
            corner(&border, cx: s, cy: s, dx: -s * 0.38, dy: -s * 0.38)
            ctx.stroke(border, with: .color(.white), lineWidth: bw)

            // Inner rect with accent
            let rx = s * 0.293, ry = s * 0.379
            let rw = s * 0.414, rh = s * 0.241
            let rect = Path(roundedRect: CGRect(x: rx, y: ry, width: rw, height: rh), cornerRadius: 3)
            ctx.stroke(rect, with: .color(Color.strgAccent), lineWidth: bw)

            // Center dot
            let dot = Path(ellipseIn: CGRect(x: s * 0.5 - 4, y: s * 0.5 - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(Color.strgAccent))
        }
        .frame(width: 58, height: 58)
    }

    private func corner(_ path: inout Path, cx: CGFloat, cy: CGFloat, dx: CGFloat, dy: CGFloat) {
        path.move(to: CGPoint(x: cx + dx * 0.5, y: cy))
        path.addLine(to: CGPoint(x: cx + dx * 0.5, y: cy + dy * 0.3))
        path.addLine(to: CGPoint(x: cx + dx * 0.3, y: cy + dy * 0.3))
        path.addLine(to: CGPoint(x: cx + dx * 0.3, y: cy + dy * 0.5))
    }
}
