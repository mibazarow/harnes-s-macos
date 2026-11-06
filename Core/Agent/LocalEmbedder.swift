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

    private let modelDirectory: URL
    private var session: ORTSessionBox?
    private var tokenizer: TokenizerLoader.Handle?

    private let maxSequenceLength = 512
    /// The model takes a batch, but a big one multiplies peak memory. Eight keeps a
    /// 512-token window comfortably inside a few hundred megabytes.
    private let batchSize = 8

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
        tokenizer = try await TokenizerLoader.load(folder: modelDirectory)

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
        let batch = try await embed([text])
        guard let first = batch.first else {
            throw NSError(domain: "LocalEmbedder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Пустой эмбеддинг"
            ])
        }
        return first
    }

    /// Batched embed. One tokenizer call and one model run per batch instead of per
    /// chunk: on a large index this is the difference between minutes and seconds.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await prepare()
        guard !texts.isEmpty else { return [] }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        var start = 0
        while start < texts.count {
            let end = min(start + batchSize, texts.count)
            let slice = Array(texts[start..<end])
            do {
                results.append(contentsOf: try run(slice))
            } catch {
                // A model that rejects batching still works one text at a time.
                for text in slice {
                    results.append(try run([text]).first ?? [])
                }
            }
            start = end
        }
        return results
    }

    private func run(_ texts: [String]) throws -> [[Float]] {
        #if canImport(OnnxRuntimeBindings)
        guard let box = session, let tokenizer else {
            throw NSError(domain: "LocalEmbedder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Эмбеддер не готов"
            ])
        }

        let encoded = texts.map { tokenizer.encode($0, maxLength: maxSequenceLength) }
        let length = encoded.map(\.count).max() ?? 0
        guard length > 0 else { return [] }

        // Right-pad to the longest text; the mask keeps padding out of attention.
        var inputIDs = [Int64](repeating: 0, count: encoded.count * length)
        var mask = [Int64](repeating: 0, count: encoded.count * length)
        for (row, ids) in encoded.enumerated() {
            for (column, id) in ids.enumerated() {
                inputIDs[row * length + column] = Int64(id)
                mask[row * length + column] = 1
            }
        }

        let shape: [NSNumber] = [NSNumber(value: encoded.count), NSNumber(value: length)]
        let inputIDsValue = try ORTValue(
            tensorData: NSMutableData(data: inputIDs.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .int64,
            shape: shape
        )
        let maskValue = try ORTValue(
            tensorData: NSMutableData(data: mask.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .int64,
            shape: shape
        )
        let emptyFeatures = try ORTValue(
            tensorData: NSMutableData(data: Data()),
            elementType: .float,
            shape: [0, 512]
        )

        let outputs = try box.session.run(
            withInputs: [
                "input_ids": inputIDsValue,
                "attention_mask": maskValue,
                "image_features": emptyFeatures,
                "video_features": emptyFeatures,
                "audio_features": emptyFeatures
            ],
            outputNames: Set(["sentence_embedding"]),
            runOptions: nil
        )

        guard let sentence = outputs["sentence_embedding"],
              let raw = try? sentence.tensorData() else {
            throw NSError(domain: "LocalEmbedder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Модель не вернула sentence_embedding"
            ])
        }

        var flat = [Float](repeating: 0, count: raw.count / 4)
        _ = flat.withUnsafeMutableBytes { raw.copyBytes(to: $0) }

        let dimension = flat.count / max(encoded.count, 1)
        guard dimension > 0 else { return [] }

        return (0..<encoded.count).map { row in
            var values = Array(flat[(row * dimension)..<((row + 1) * dimension)])
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                for index in values.indices { values[index] /= norm }
            }
            return values
        }
        #else
        throw NSError(domain: "LocalEmbedder", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "OnnxRuntimeBindings не подключён"
        ])
        #endif
    }
}
