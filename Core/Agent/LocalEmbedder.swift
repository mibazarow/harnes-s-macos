import Foundation

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// Local EmbeddingGemma 2 backend: tokenizer (swift-transformers) + ONNX Runtime.
/// Produces 768-dim L2-normalized vectors without any network calls.
actor LocalEmbedder {
    enum State: Sendable {
        case unavailable(String)
        case loading
        case ready
    }

    private(set) var state: State = .unavailable("не инициализирован")
    private(set) var modelName: String = "embeddinggemma-2"

    private let modelDirectory: URL
    private var session: ORTSessionBox?
    private var tokenizer: TokenizerLoader.Handle?

    private let maxSequenceLength = 512

    init(modelDirectory: URL = AppPaths.modelsDirectory.appendingPathComponent("embeddinggemma-2", isDirectory: true)) {
        self.modelDirectory = modelDirectory
    }

    nonisolated var isAvailableOnDisk: Bool {
        let model = modelDirectory.appendingPathComponent("model_quantized.onnx")
        let data = modelDirectory.appendingPathComponent("model_quantized.onnx_data")
        let tokenizer = modelDirectory.appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: model.path)
            && FileManager.default.fileExists(atPath: data.path)
            && FileManager.default.fileExists(atPath: tokenizer.path)
    }

    func prepare() async throws {
        guard case .ready = state else {
            state = .loading
            do {
                try await load()
                state = .ready
            } catch {
                state = .unavailable(error.localizedDescription)
                throw error
            }
            return
        }
    }

    private func load() async throws {
        guard isAvailableOnDisk else {
            throw NSError(domain: "LocalEmbedder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Модель EmbeddingGemma не найдена в \(modelDirectory.path)"
            ])
        }

        #if canImport(OnnxRuntimeBindings)
        let tokenizerURL = modelDirectory.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        let tokenizerJSON = try JSONSerialization.jsonObject(with: tokenizerData)
        _ = tokenizerJSON

        let tokenizerConfigURL = modelDirectory.appendingPathComponent("tokenizer_config.json")
        let configData = try Data(contentsOf: tokenizerConfigURL)
        _ = configData

        // swift-transformers loads from a folder; keep it as an opaque handle.
        tokenizer = try await TokenizerLoader.load(folder: modelDirectory)
        _ = tokenizer

        let modelPath = modelDirectory.appendingPathComponent("model_quantized.onnx").path
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.basic)
        try options.setIntraOpNumThreads(4)
        session = ORTSessionBox(session: try ORTSession(env: env, modelPath: modelPath, sessionOptions: options))
        #else
        throw NSError(domain: "LocalEmbedder", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "OnnxRuntimeBindings не подключён"
        ])
        #endif
    }

    private struct ORTSessionBox {
        let session: ORTSession
    }

    func embed(_ text: String) async throws -> [Float] {
        try await prepare()

        #if canImport(OnnxRuntimeBindings)
        guard let box = session, let tokenizer else {
            throw NSError(domain: "LocalEmbedder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Эмбеддер не готов"
            ])
        }

        let ids = tokenizer.encode(text, maxLength: maxSequenceLength)
        let shape: [NSNumber] = [1, NSNumber(value: ids.count)]

        var inputIDs = ids.map { Int64($0) }
        let inputIDsData = inputIDs.withUnsafeBufferPointer { Data(buffer: $0) }
        let inputIDsValue = try ORTValue(
            tensorData: NSMutableData(data: inputIDsData),
            elementType: .int64,
            shape: shape
        )

        var mask = [Int64](repeating: 1, count: ids.count)
        let maskData = mask.withUnsafeBufferPointer { Data(buffer: $0) }
        let maskValue = try ORTValue(
            tensorData: NSMutableData(data: maskData),
            elementType: .int64,
            shape: shape
        )

        let emptyFeatures = try ORTValue(
            tensorData: NSMutableData(data: Data()),
            elementType: .float,
            shape: [0, 512]
        )

        let inputs: [String: ORTValue] = [
            "input_ids": inputIDsValue,
            "attention_mask": maskValue,
            "image_features": emptyFeatures,
            "video_features": emptyFeatures,
            "audio_features": emptyFeatures
        ]

        let outputs = try box.session.run(
            withInputs: inputs,
            outputNames: Set(["sentence_embedding"]),
            runOptions: nil
        )

        guard let sentence = outputs["sentence_embedding"],
              let raw = try? sentence.tensorData() else {
            throw NSError(domain: "LocalEmbedder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Модель не вернула sentence_embedding"
            ])
        }

        var values = [Float](repeating: 0, count: raw.count / 4)
        _ = values.withUnsafeMutableBytes { raw.copyBytes(to: $0) }

        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            values = values.map { $0 / norm }
        }
        inputIDs.removeAll()
        mask.removeAll()
        return values
        #else
        throw NSError(domain: "LocalEmbedder", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "OnnxRuntimeBindings не подключён"
        ])
        #endif
    }
}