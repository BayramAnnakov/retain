import Foundation

/// Ollama local LLM service for embeddings.
/// Provides higher-quality embeddings than Apple NL when Ollama is installed.
///
/// Recommended model: EmbeddingGemma (best quality-to-size ratio, 768 dims)
/// - Install: `brew install ollama && ollama pull embeddinggemma`
actor OllamaService: EmbeddingProvider {

    // MARK: - EmbeddingProvider

    /// Default model - EmbeddingGemma is the best open-source embedding model under 500M params
    static let defaultModel = "embeddinggemma"

    let name = "Ollama"

    /// Vector dimensions based on configured model
    var dimensions: Int {
        switch config.embeddingModel {
        case "embeddinggemma": return 768
        case "nomic-embed-text": return 768
        case "all-minilm": return 384
        case "mxbai-embed-large": return 1024
        default: return 768
        }
    }

    // MARK: - Configuration

    struct Configuration {
        var endpoint: String = "http://localhost:11434"
        var embeddingModel: String = OllamaService.defaultModel
        var timeout: TimeInterval = 30

        init(endpoint: String = "http://localhost:11434",
             model: String = OllamaService.defaultModel,
             timeout: TimeInterval = 30) {
            self.endpoint = endpoint
            self.embeddingModel = model
            self.timeout = timeout
        }
    }

    // MARK: - API Types

    struct EmbeddingRequest: Encodable {
        let model: String
        let prompt: String
    }

    struct EmbeddingResponse: Decodable {
        let embedding: [Float]
    }

    struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: GenerateOptions?
    }

    struct GenerateOptions: Encodable {
        let temperature: Double?
        let num_predict: Int?
    }

    struct GenerateResponse: Decodable {
        let response: String
    }

    struct ModelsResponse: Decodable {
        let models: [Model]

        struct Model: Decodable {
            let name: String
            let modified_at: String?
            let size: Int64?
        }
    }

    // MARK: - Properties

    private var config: Configuration
    private let session: URLSession

    // MARK: - Init

    init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Configuration

    func updateConfiguration(_ config: Configuration) {
        self.config = config
    }

    // MARK: - Health Check

    /// Check if Ollama is running and model is available
    func isAvailable() async -> Bool {
        do {
            let models = try await listModels()
            return models.contains { $0.name.contains(config.embeddingModel) }
        } catch {
            return false
        }
    }

    func isModelAvailable(_ model: String) async -> Bool {
        do {
            let models = try await listModels()
            return models.contains { $0.name.contains(model) }
        } catch {
            return false
        }
    }

    /// List available models
    func listModels() async throws -> [ModelsResponse.Model] {
        let url = URL(string: "\(config.endpoint)/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.connectionFailed
        }

        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.models
    }

    // MARK: - Embeddings

    /// Generate embedding for text
    func embed(text: String) async throws -> [Float] {
        let url = URL(string: "\(config.endpoint)/api/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout

        let body = EmbeddingRequest(model: config.embeddingModel, prompt: text)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.connectionFailed
        }

        switch httpResponse.statusCode {
        case 200:
            let embeddingResponse = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
            return embeddingResponse.embedding
        case 404:
            throw OllamaError.modelNotFound(config.embeddingModel)
        default:
            throw OllamaError.requestFailed(httpResponse.statusCode)
        }
    }

    /// Generate text with a local LLM
    func generate(prompt: String, model: String, options: GenerateOptions? = nil) async throws -> String {
        let url = URL(string: "\(config.endpoint)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout

        let body = GenerateRequest(model: model, prompt: prompt, stream: false, options: options)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.connectionFailed
        }

        switch httpResponse.statusCode {
        case 200:
            let generateResponse = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return generateResponse.response
        case 404:
            throw OllamaError.modelNotFound(model)
        default:
            throw OllamaError.requestFailed(httpResponse.statusCode)
        }
    }

    /// Generate embeddings for multiple texts (protocol conformance)
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        return try await embedBatchWithSize(texts: texts, batchSize: 10)
    }

    /// Generate embeddings for multiple texts with custom batch size
    func embedBatchWithSize(texts: [String], batchSize: Int = 10) async throws -> [[Float]] {
        var embeddings: [[Float]] = []

        for i in stride(from: 0, to: texts.count, by: batchSize) {
            let batch = Array(texts[i..<min(i + batchSize, texts.count)])

            for text in batch {
                let embedding = try await embed(text: text)
                embeddings.append(embedding)
            }

            // Small delay between batches
            if i + batchSize < texts.count {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        return embeddings
    }

    // MARK: - Errors

    enum OllamaError: LocalizedError {
        case connectionFailed
        case modelNotFound(String)
        case requestFailed(Int)

        var errorDescription: String? {
            switch self {
            case .connectionFailed:
                return "Could not connect to Ollama. Make sure it's running on localhost:11434"
            case .modelNotFound(let model):
                return "Model '\(model)' not found. Run: ollama pull \(model)"
            case .requestFailed(let code):
                return "Request failed with status \(code)"
            }
        }
    }
}

// MARK: - Vector Math

extension Array where Element == Float {
    /// Cosine similarity between two vectors
    func cosineSimilarity(with other: [Float]) -> Float {
        guard count == other.count, !isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<count {
            dotProduct += self[i] * other[i]
            normA += self[i] * self[i]
            normB += other[i] * other[i]
        }

        let magnitude = sqrt(normA) * sqrt(normB)
        guard magnitude > 0 else { return 0 }

        return dotProduct / magnitude
    }

    /// Convert to Data for storage
    func toData() -> Data {
        withUnsafeBytes { Data($0) }
    }

    /// Create from Data
    static func fromData(_ data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
