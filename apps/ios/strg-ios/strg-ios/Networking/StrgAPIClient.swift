import Foundation
import UIKit
import Observation

/// Client for the strg-model workout extraction API.
@Observable
public final class StrgAPIClient {
    private var baseURL: URL
    private var session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL = URL(string: "http://localhost:8000")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    /// Update the server URL (e.g. when user types a new address).
    public func setServerURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        baseURL = url
    }



    // MARK: - Health Check

    /// Check if the API server is reachable and healthy.
    public func health() async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("health")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(HealthResponse.self, from: data)
    }

    // MARK: - Predict

    /// Upload a workout journal photo and get structured workout data.
    /// - Parameter image: The photo to analyze (JPEG preferred).
    /// - Returns: Extracted workout entries with latency info.
    public func predict(image: UIImage) async throws -> PredictionResponse {
        let url = baseURL.appendingPathComponent("predict")

        // Convert image to JPEG data
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw StrgAPIError.imageConversionFailed
        }

        // Build multipart form request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(PredictionResponse.self, from: data)
    }

    // MARK: - Feedback

    /// Submit corrected workout data for future fine-tuning.
    @discardableResult
    public func submitFeedback(
        image: UIImage,
        entries: [WorkoutEntry],
        originalEntries: [WorkoutEntry]? = nil,
        notes: String? = nil
    ) async throws -> FeedbackResponse {
        let url = baseURL.appendingPathComponent("feedback")

        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw StrgAPIError.imageConversionFailed
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let encoder = JSONEncoder()
        let entriesData = try encoder.encode(entries)
        let entriesJSON = String(data: entriesData, encoding: .utf8)!

        var body = Data()

        // Image
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // Corrected entries
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"entries\"\r\n\r\n".data(using: .utf8)!)
        body.append(entriesJSON.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // Original entries (optional)
        if let original = originalEntries {
            let origData = try encoder.encode(original)
            let origJSON = String(data: origData, encoding: .utf8)!
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"original_entries\"\r\n\r\n".data(using: .utf8)!)
            body.append(origJSON.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        // Notes (optional)
        if let notes = notes {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"notes\"\r\n\r\n".data(using: .utf8)!)
            body.append(notes.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(FeedbackResponse.self, from: data)
    }
}

// MARK: - Errors

public enum StrgAPIError: LocalizedError {
    case imageConversionFailed
    case serverError(String)
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image to JPEG"
        case .serverError(let msg):
            return "Server error: \(msg)"
        case .decodingFailed:
            return "Failed to decode server response"
        }
    }
}
