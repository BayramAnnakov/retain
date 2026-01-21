import XCTest
@testable import Retain

/// Unit tests for OllamaService
final class OllamaServiceTests: XCTestCase {

    // MARK: - Default Model Tests

    func testDefaultModel() {
        XCTAssertEqual(OllamaService.defaultModel, "embeddinggemma", "Default model should be embeddinggemma")
    }

    // MARK: - Dimensions Tests

    func testDimensionsForEmbeddingGemma() async {
        let service = OllamaService(configuration: .init(model: "embeddinggemma"))
        let dims = await service.dimensions
        XCTAssertEqual(dims, 768, "EmbeddingGemma should have 768 dimensions")
    }

    func testDimensionsForNomicEmbedText() async {
        let service = OllamaService(configuration: .init(model: "nomic-embed-text"))
        let dims = await service.dimensions
        XCTAssertEqual(dims, 768, "Nomic-embed-text should have 768 dimensions")
    }

    func testDimensionsForAllMinilm() async {
        let service = OllamaService(configuration: .init(model: "all-minilm"))
        let dims = await service.dimensions
        XCTAssertEqual(dims, 384, "All-minilm should have 384 dimensions")
    }

    func testDimensionsForMxbaiEmbedLarge() async {
        let service = OllamaService(configuration: .init(model: "mxbai-embed-large"))
        let dims = await service.dimensions
        XCTAssertEqual(dims, 1024, "Mxbai-embed-large should have 1024 dimensions")
    }

    func testDimensionsForUnknownModel() async {
        let service = OllamaService(configuration: .init(model: "unknown-model"))
        let dims = await service.dimensions
        XCTAssertEqual(dims, 768, "Unknown model should default to 768 dimensions")
    }

    // MARK: - Name Tests

    func testName() async {
        let service = OllamaService()
        let name = await service.name
        XCTAssertEqual(name, "Ollama")
    }

    // MARK: - Configuration Tests

    func testConfigurationDefaults() {
        let config = OllamaService.Configuration()

        XCTAssertEqual(config.endpoint, "http://localhost:11434")
        XCTAssertEqual(config.embeddingModel, "embeddinggemma")
        XCTAssertEqual(config.timeout, 30)
    }

    func testConfigurationCustomValues() {
        let config = OllamaService.Configuration(
            endpoint: "http://custom:8080",
            model: "all-minilm",
            timeout: 60
        )

        XCTAssertEqual(config.endpoint, "http://custom:8080")
        XCTAssertEqual(config.embeddingModel, "all-minilm")
        XCTAssertEqual(config.timeout, 60)
    }

    func testUpdateConfiguration() async {
        let service = OllamaService()
        let newConfig = OllamaService.Configuration(model: "all-minilm")

        await service.updateConfiguration(newConfig)

        let dims = await service.dimensions
        XCTAssertEqual(dims, 384, "Dimensions should update after configuration change")
    }

    // MARK: - Availability Tests (when Ollama not running)

    func testIsAvailableWhenNotRunning() async {
        // Use invalid endpoint to simulate Ollama not running
        let service = OllamaService(configuration: .init(endpoint: "http://localhost:99999"))
        let available = await service.isAvailable()
        XCTAssertFalse(available, "Should not be available with invalid endpoint")
    }

    // MARK: - Error Handling Tests

    func testEmbedThrowsWhenNotRunning() async {
        let service = OllamaService(configuration: .init(endpoint: "http://localhost:99999"))

        do {
            _ = try await service.embed(text: "test")
            XCTFail("Should throw when Ollama not running")
        } catch {
            // Expected - connection should fail
            XCTAssertTrue(error is OllamaService.OllamaError || error is URLError)
        }
    }

    // MARK: - Integration Tests (require running Ollama)

    func testEmbedWhenAvailable() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running - start with: ollama serve")
        }

        let vector = try await service.embed(text: "Hello world")
        let expectedDims = await service.dimensions

        XCTAssertEqual(vector.count, expectedDims, "Should return vector with correct dimensions")
        XCTAssertGreaterThan(vector.filter { $0 != 0 }.count, 0, "Vector should not be all zeros")
    }

    func testListModelsWhenAvailable() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running - start with: ollama serve")
        }

        let models = try await service.listModels()
        XCTAssertGreaterThan(models.count, 0, "Should list at least one model")

        print("Available Ollama models:")
        for model in models {
            print("  - \(model.name)")
        }
    }

    func testBatchEmbedWhenAvailable() async throws {
        let service = OllamaService()

        guard await service.isAvailable() else {
            throw XCTSkip("Ollama not running - start with: ollama serve")
        }

        let texts = ["Hello", "World", "Test"]
        let vectors = try await service.embedBatch(texts: texts)

        XCTAssertEqual(vectors.count, 3, "Should return vector for each input")

        let expectedDims = await service.dimensions
        for vec in vectors {
            XCTAssertEqual(vec.count, expectedDims)
        }
    }

    // MARK: - Error Description Tests

    func testConnectionFailedError() {
        let error = OllamaService.OllamaError.connectionFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("localhost:11434") ?? false)
    }

    func testModelNotFoundError() {
        let error = OllamaService.OllamaError.modelNotFound("test-model")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("test-model") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("ollama pull") ?? false)
    }

    func testRequestFailedError() {
        let error = OllamaService.OllamaError.requestFailed(500)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("500") ?? false)
    }
}
