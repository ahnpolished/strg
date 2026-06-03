import SwiftUI

// MARK: - Legacy compat

/// Prefer `glassSurface()` from `GlassModifiers.swift` instead.
@available(*, deprecated, message: "Use .glassSurface() from DesignSystem/GlassModifiers.swift")
struct GlassCardModifier: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content.glassSurface(radius: radius)
    }
}

extension View {
    @available(*, deprecated, message: "Use .glassSurface() from DesignSystem/GlassModifiers.swift")
    func glassCard(radius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }
}
