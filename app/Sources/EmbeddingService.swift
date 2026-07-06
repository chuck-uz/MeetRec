// Локальные эмбеддинги через llama-server с моделью bge-m3 (мультиязычная,
// сильна в русском). Отдельный процесс на 127.0.0.1, данные не покидают Mac.
import Foundation

struct EmbedSpec {
    static let file = "bge-m3-Q4_K_M.gguf"
    static let title = "bge-m3"
    static let url =
        "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q4_K_M.gguf"
    static let dimension = 1024

    static var current: EmbedSpec { EmbedSpec() }
    static var modelURL: URL {
        Transcriber.modelsDir.appendingPathComponent(file)
    }
}

actor EmbeddingService {
    static let shared = EmbeddingService()

    private var server: Process?
    private var port = 0

    /// Считает эмбеддинги пачкой (bge-m3, CLS-пулинг). Порядок сохраняется.
    func embed(_ texts: [String], onStatus: (@Sendable (String) -> Void)? = nil) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let port = try await ensureServer(onStatus: onStatus)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": texts])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetRecError("Сервис эмбеддингов вернул ошибку.")
        }
        struct EmbedResponse: Decodable {
            struct Item: Decodable { let index: Int; let embedding: [Float] }
            let data: [Item]
        }
        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    /// Останавливает сервер эмбеддингов — освобождает ~0,5 ГБ.
    func shutdown() {
        server?.terminate()
        server = nil
    }

    private func ensureServer(onStatus: (@Sendable (String) -> Void)?) async throws -> Int {
        if let server, server.isRunning { return port }
        shutdown()

        guard let binary = LLMRuntime.serverBinary() else {
            throw MeetRecError("Не найден llama-server. Переустановите MeetRec.")
        }
        let modelPath = EmbedSpec.modelURL
        if !FileManager.default.fileExists(atPath: modelPath.path) {
            onStatus?("скачивание модели поиска \(EmbedSpec.title) (~0,4 ГБ)…")
            guard let url = URL(string: EmbedSpec.url) else {
                throw MeetRecError("Некорректный адрес модели эмбеддингов.")
            }
            try await Downloader.fetch(from: url, to: modelPath, label: "модель поиска", progress: { onStatus?($0) })
        }

        let chosenPort = Int.random(in: 49500..<64000)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelPath.path,
            "--host", "127.0.0.1",
            "--port", "\(chosenPort)",
            "--embedding",
            "--pooling", "cls",   // bge-m3 использует CLS-пулинг
            "-c", "8192",
            "-ngl", "99",
            "--no-webui",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        server = process
        port = chosenPort

        let health = URL(string: "http://127.0.0.1:\(chosenPort)/health")!
        for _ in 0..<120 {
            if !process.isRunning {
                throw MeetRecError("Сервер эмбеддингов завершился при запуске.")
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return chosenPort
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        shutdown()
        throw MeetRecError("Модель поиска не загрузилась за отведённое время.")
    }
}
