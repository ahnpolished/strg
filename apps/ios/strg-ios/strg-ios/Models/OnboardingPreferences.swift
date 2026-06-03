import Foundation

/// User notation / calibration preferences set during onboarding.
/// Persisted in UserDefaults so the app — and eventually the OCR parser — can
/// honour them.
struct OnboardingPreferences: Codable, Equatable {
    /// Notation ordering: "nwrn" = Name·Weight·Reps·Note, "nsw" = Name·Sets×Reps·Weight, etc.
    var order: String = "nwrn"
    /// Value separator glyph id: "space", "pipe", "dash", "slash".
    var separator: String = "pipe"
    /// Sets × reps notation id: "x" = 4×8, "lowx" = 4x8, "list" = 8·8·8·8, "sets" = 3 × 5.
    var setsReps: String = "x"
    /// Preferred weight unit: "LBS" or "KG".
    var unit: String = "LBS"
}

// MARK: - Persistence

extension OnboardingPreferences {
    private static let key = "strg.onboardingPrefs.v1"

    static func load() -> OnboardingPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(OnboardingPreferences.self, from: data)
        else { return OnboardingPreferences() }
        return prefs
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

extension OnboardingPreferences {
    /// Returns whether the user has completed onboarding at least once.
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: "strg.onboarding.completed.v1")
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: "strg.onboarding.completed.v1")
    }
}
