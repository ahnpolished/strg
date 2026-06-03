import SwiftUI

// MARK: - Color Tokens

extension Color {
    /// App canvas — near-black (#080808).
    static let strgBg = Color(red: 0.031, green: 0.031, blue: 0.031)

    /// Primary accent — burnt orange (#FF4B00).
    static let strgAccent = Color(red: 1.0, green: 0.294, blue: 0.0)

    // MARK: Text colors
    static let strgTextPrimary = Color.white
    static let strgTextSecondary = Color.white.opacity(0.45)
    static let strgTextTertiary = Color.white.opacity(0.25)
    static let strgTextAccent = Color.strgAccent

    // MARK: Surface colors
    static let strgSurfaceGlass = Color.white.opacity(0.04)
    static let strgBorderGlass = Color.white.opacity(0.07)
    static let strgBorderStrong = Color.white.opacity(0.12)
}

// MARK: - Typography Presets

extension Font {
    /// App wordmark — 28pt black with 4pt tracking.
    static let strgWordmark: Font = .system(size: 28, weight: .black)

    /// Exercise headline — 17pt bold uppercase.
    static let strgExerciseName: Font = .system(size: 17, weight: .bold)

    /// Big number — 32pt black rounded for sets×reps.
    static let strgBigNumber: Font = .system(size: 32, weight: .black, design: .rounded)

    /// Weight value — 28pt black rounded, accent colored.
    static let strgWeightValue: Font = .system(size: 28, weight: .black, design: .rounded)

    /// Weight value (hero variant) — 40pt.
    static let strgWeightHero: Font = .system(size: 40, weight: .black, design: .rounded)

    /// Section label — 11pt semibold with 2.5pt tracking, uppercase.
    static let strgSectionLabel: Font = .system(size: 11, weight: .semibold)

    /// Micro label — 9pt semibold with 1.5pt tracking, uppercase.
    static let strgMicroLabel: Font = .system(size: 9, weight: .semibold)

    /// Notes — 13pt regular italic.
    static let strgNotes: Font = .system(size: 13).italic()

    /// Status — 11pt semibold monospaced for latency badge.
    static let strgStatus: Font = .system(size: 11, weight: .semibold, design: .monospaced)

    /// Session date — 24pt black rounded.
    static let strgSessionDate: Font = .system(size: 24, weight: .black, design: .rounded)

    /// CTA button — 13pt heavy with 2.5pt tracking, uppercase.
    static let strgCTA: Font = .system(size: 13, weight: .heavy)

    /// Onboarding title — 25pt bold.
    static let strgOnbTitle: Font = .system(size: 25, weight: .bold)

    /// Onboarding subtitle — 14pt regular.
    static let strgOnbSubtitle: Font = .system(size: 14)
}

// MARK: - Tracking Helpers

extension View {
    /// Apply wordmark tracking (4pt).
    func wordmarkTracking() -> some View {
        self.tracking(4)
    }

    /// Apply section label tracking (2.5pt).
    func sectionLabelTracking() -> some View {
        self.tracking(2.5)
    }

    /// Apply micro label tracking (1.5pt).
    func microLabelTracking() -> some View {
        self.tracking(1.5)
    }
}

// MARK: - Section Label Style

struct SectionLabelStyle: ViewModifier {
    var color: Color = .white.opacity(0.45)
    var tracking: CGFloat = 2.5

    func body(content: Content) -> some View {
        content
            .font(.strgSectionLabel)
            .foregroundStyle(color)
            .tracking(tracking)
            .textCase(.uppercase)
    }
}

struct MicroLabelStyle: ViewModifier {
    var color: Color = .white.opacity(0.25)

    func body(content: Content) -> some View {
        content
            .font(.strgMicroLabel)
            .foregroundStyle(color)
            .microLabelTracking()
            .textCase(.uppercase)
    }
}

extension View {
    func sectionLabelStyle(color: Color = .white.opacity(0.45)) -> some View {
        modifier(SectionLabelStyle(color: color))
    }

    func microLabelStyle(color: Color = .white.opacity(0.25)) -> some View {
        modifier(MicroLabelStyle(color: color))
    }
}
