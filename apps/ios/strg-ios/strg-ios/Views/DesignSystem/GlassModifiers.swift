import SwiftUI

// MARK: - Glass Surface Modifiers

/// Obsidian Glass card surface — ultraThinMaterial + subtle border + shadow.
/// The primary glass treatment used throughout strg.
struct GlassSurfaceModifier: ViewModifier {
    var radius: CGFloat = 20
    var intensity: GlassIntensity = .standard

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.white.opacity(intensity.borderOpacity), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(
                color: .black.opacity(0.5),
                radius: intensity.shadowRadius,
                x: 0, y: intensity.shadowY
            )
    }
}

/// Elevated glass — slightly more opaque, stronger border, used for
/// modal panels and processing overlays.
struct ElevatedGlassModifier: ViewModifier {
    var radius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.6), radius: 36, x: 0, y: 16)
    }
}

/// Subtle glass — minimal material, used for nested surfaces and
/// option cards where too much blur would clutter.
struct SubtleGlassModifier: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.white.opacity(0.035))
            }
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
    }
}

/// Glass intensity presets controlling border opacity and shadow depth.
enum GlassIntensity {
    case light
    case standard
    case heavy

    var borderOpacity: CGFloat {
        switch self {
        case .light: return 0.05
        case .standard: return 0.07
        case .heavy: return 0.12
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .light: return 12
        case .standard: return 24
        case .heavy: return 36
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .light: return 4
        case .standard: return 8
        case .heavy: return 16
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply the primary Obsidian Glass card surface.
    func glassSurface(radius: CGFloat = 20, intensity: GlassIntensity = .standard) -> some View {
        modifier(GlassSurfaceModifier(radius: radius, intensity: intensity))
    }

    /// Elevated glass for modal panels.
    func elevatedGlass(radius: CGFloat = 28) -> some View {
        modifier(ElevatedGlassModifier(radius: radius))
    }

    /// Subtle glass for nested/option surfaces.
    func subtleGlass(radius: CGFloat = 20) -> some View {
        modifier(SubtleGlassModifier(radius: radius))
    }

    /// Glass capture circle — the large scan button treatment.
    func glassCaptureCircle(size: CGFloat = 160) -> some View {
        self
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            .clipShape(Circle())
            .shadow(
                color: Color.strgAccent.opacity(0.18),
                radius: 30
            )
            .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 16)
    }

    /// Tab bar glass treatment — darker, with top hairline.
    func glassTabBar() -> some View {
        self
            .background {
                ZStack {
                    Color(red: 0.055, green: 0.055, blue: 0.055).opacity(0.55)
                        .background(.ultraThinMaterial)
                    VStack {
                        Color.white.opacity(0.08).frame(height: 0.5)
                        Spacer()
                    }
                }
            }
    }

    /// Glass pill badge — small translucent capsule for labels/counts.
    func glassPill() -> some View {
        self
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
    }
}

// MARK: - Accent Button Style

/// Primary CTA button — solid accent fill with inner highlight + glow shadow.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(.white)
            .tracking(2.5)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.strgAccent)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .clear],
                                    startPoint: .top, endPoint: .center
                                )
                            )
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(
                color: Color.strgAccent.opacity(0.45),
                radius: 22, x: 0, y: 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary outline button — subtle glass with border.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(0.7))
            .tracking(2)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color.white.opacity(0.05))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Animation Presets

/// Shared animation presets matching the Obsidian Glass design language.
enum StrgAnimation {
    /// Card entrance — spring with damping, used for staggered list animations.
    static let cardEntrance = Animation.spring(
        response: 0.5,
        dampingFraction: 0.8,
        blendDuration: 0
    )

    /// Screen transition — smooth ease-in-out for flow changes.
    static let screenTransition = Animation.easeInOut(duration: 0.28)

    /// Button press — quick spring for tactile feedback.
    static let buttonPress = Animation.spring(
        response: 0.3,
        dampingFraction: 0.7
    )

    /// Pulsing ring — slow, deliberate breathing used on capture screen.
    static let pulse = Animation.easeInOut(duration: 2.5)

    /// Tab bar show/hide.
    static let tabBar = Animation.easeInOut(duration: 0.22)
}

// MARK: - Sensory Feedback

extension View {
    /// Add light haptic feedback on tap — use on primary actions.
    func sensoryTap() -> some View {
        #if os(iOS)
        self.sensoryFeedback(.impact(weight: .light), trigger: UUID())
        #else
        self
        #endif
    }
}
