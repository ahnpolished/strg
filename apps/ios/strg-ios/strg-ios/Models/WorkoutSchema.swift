import Foundation

// MARK: - Workout Schema (mirrors common/schema.py)

/// A single workout set entry extracted from a journal photo.
public struct WorkoutEntry: Codable, Identifiable, Equatable {
    public var id: String { "\(date)-\(exercise)-\(sets)-\(reps)" }

    public let date: String?
    public let exercise: String
    public let sets: Int
    public let reps: Int
    public let weightKg: Double?
    public let weightLbs: Double?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case date, exercise, sets, reps
        case weightKg = "weight_kg"
        case weightLbs = "weight_lbs"
        case notes
    }
}

/// A page of workout entries (the full extraction result).
public struct WorkoutPage: Codable {
    public let entries: [WorkoutEntry]
}

/// Feedback submission response.
public struct FeedbackResponse: Codable {
    public let status: String
    public let feedbackId: String
    public let entriesSaved: Int

    enum CodingKeys: String, CodingKey {
        case status
        case feedbackId = "feedback_id"
        case entriesSaved = "entries_saved"
    }
}

/// API prediction response envelope.
public struct PredictionResponse: Codable {
    public let entries: [WorkoutEntry]
    public let latencyS: Double
    public let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case entries
        case latencyS = "latency_s"
        case entryCount = "entry_count"
    }
}

/// API health check response.
public struct HealthResponse: Codable {
    public let status: String
    public let model: String
    public let loraCheckpoint: String?
    public let device: String?

    enum CodingKeys: String, CodingKey {
        case status, model, device
        case loraCheckpoint = "lora_checkpoint"
    }
}
