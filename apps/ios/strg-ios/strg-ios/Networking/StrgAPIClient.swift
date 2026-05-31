import Foundation
import UIKit

/// Client for the strg-model workout extraction API.
public final class StrgAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL = URL(string: "http://localhost:8000")!) {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
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
