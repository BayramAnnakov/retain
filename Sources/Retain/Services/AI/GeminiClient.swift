import Foundation

/// Minimal Gemini API client for structured output.
actor GeminiClient {
    struct Configuration: Sendable {
        let apiKey: String
        let model: String
        let baseURL: URL
        let timeout: TimeInterval

        init(apiKey: String, model: String) {
            self.apiKey = apiKey
            self.model = model
            self.baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            self.timeout = 30
        }
    }

    enum GeminiError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        case emptyResponse
        case invalidApiKey
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from Gemini"
            case .httpError(let code, let message):
                return "Gemini API error \(code): \(message)"
            case .emptyResponse:
                return "Gemini returned empty response"
            case .invalidApiKey:
                return "Invalid API key"
            case .networkError(let message):
                return "Network error: \(message)"
            }
        }
    }

    /// Result of API key validation
    enum ValidationResult: Sendable {
        case valid
        case invalid(String)
        case networkError(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        var errorMessage: String? {
            switch self {
            case .valid: return nil
            case .invalid(let msg): return msg
            case .networkError(let msg): return msg
            }
        }
    }

    /// Validate a Gemini API key by making a minimal test request
    /// Uses the models list endpoint which is lightweight and doesn't cost tokens
    static func validateApiKey(_ apiKey: String) async -> ValidationResult {
        guard !apiKey.isEmpty else {
            return .invalid("API key is empty")
        }

        // Use the models list endpoint - it's free and validates the key
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError("Invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                return .valid
            case 400:
                // Check if it's specifically an API key error
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return .invalid(message)
                }
                return .invalid("Bad request")
            case 401, 403:
                return .invalid("Invalid or unauthorized API key")
            case 429:
                // Rate limited but key is valid
                return .valid
            default:
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .invalid("HTTP \(httpResponse.statusCode): \(message)")
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet:
                return .networkError("No internet connection")
            case .timedOut:
                return .networkError("Request timed out")
            default:
                return .networkError(error.localizedDescription)
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? URLSession(configuration: .default)
    }

    func generateStructuredContent(prompt: String, schema: [String: Any]) async throws -> String {
        let url = configuration.baseURL
            .appendingPathComponent("\(configuration.model):generateContent")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.httpError(httpResponse.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.compactMap({ $0.text }).joined(), !text.isEmpty else {
            throw GeminiError.emptyResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content
    }

    struct Content: Decodable {
        let parts: [Part]
    }

    struct Part: Decodable {
        let text: String?
    }

    let candidates: [Candidate]
}
