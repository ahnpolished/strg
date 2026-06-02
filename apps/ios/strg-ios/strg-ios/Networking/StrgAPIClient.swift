import Foundation
import UIKit
import Observation

/// Client for the strg-model workout extraction API.
@Observable
public final class StrgAPIClient {
    private var baseURL: URL
    private var apiKey: String = ""
    private var session: URLSession
    private let decoder: JSONDecoder

    public init() {
        self.baseURL = AppConfig.serverURL
        self.apiKey = AppConfig.apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Request Builder

    private func buildRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }



    // MARK: - Health Check

    /// Check if the API server is reachable and healthy.
    public func health() async throws -> HealthResponse {
        let url = appendPath(url: baseURL, path: "health")
        var request = buildRequest(url: url)
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(HealthResponse.self, from: data)
    }

    // MARK: - Predict

    /// Upload a workout journal photo and get structured workout data.
    /// - Parameter image: The photo to analyze (JPEG preferred).
    /// - Returns: Extracted workout entries with latency info.
    public func predict(image: UIImage) async throws -> PredictionResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw StrgAPIError.imageConversionFailed
        }

        let isServerless = baseURL.absoluteString.contains("runpod.ai")
        let url: URL
        var request: URLRequest

        if isServerless {
            // RunPod Serverless: POST JSON with base64 image
            url = appendPath(url: baseURL, path: "runsync")
            request = buildRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let base64 = imageData.base64EncodedString()
            let body: [String: Any] = [
                "input": [
                    "image": base64,
                    "filename": "photo.jpg"
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            // Direct pod: multipart form upload
            url = appendPath(url: baseURL, path: "predict")
            request = buildRequest(url: url, method: "POST")
            let boundary = UUID().uuidString
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
        }

        let (data, _) = try await session.data(for: request)

        // Parse response — serverless wraps in "output" key
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let output = raw?["output"] as? [String: Any] {
            let outputData = try JSONSerialization.data(withJSONObject: output)
            return try decoder.decode(PredictionResponse.self, from: outputData)
        }
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
        let url = appendPath(url: baseURL, path: "feedback")
        var request = buildRequest(url: url, method: "POST")

        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw StrgAPIError.imageConversionFailed
        }

        let boundary = UUID().uuidString
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let encoder = JSONEncoder()
        let entriesData = try encoder.encode(entries)
        let entriesJSON = String(data: entriesData, encoding: .utf8)!

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"entries\"\r\n\r\n".data(using: .utf8)!)
        body.append(entriesJSON.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        if let original = originalEntries {
            let origData = try encoder.encode(original)
            let origJSON = String(data: origData, encoding: .utf8)!
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"original_entries\"\r\n\r\n".data(using: .utf8)!)
            body.append(origJSON.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
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

    // MARK: - Helpers

    private func appendPath(url: URL, path: String) -> URL {
        url.appendingPathComponent(path)
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
