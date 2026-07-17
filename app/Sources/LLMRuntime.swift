// Локальная LLM для чата по встречам: llama-server (llama.cpp, Metal) как
// дочерний процесс на 127.0.0.1. Всё на устройстве, данные не покидают Mac.
import Foundation

enum Hardware {
    static let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    /// Чат с ИИ доступен от 16 ГБ unified memory (модель ~4,7 ГБ + KV-кэш).
    static let supportsChat = ramGB >= 16

    /// Название процессора, напр. «Apple M2 Pro» (для экрана выбора модели).
    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}

struct LLMSpec {
    let file: String
    let url: String
    let title: String

    static let fallback = LLMSpec(
        file: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        url: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        title: "Qwen 2.5 7B")

    /// Текущая модель. Явный выбор пользователя уважаем; иначе — модель по
    /// умолчанию, подобранная под железо (LLMCatalog.defaultModel).
    static var current: LLMSpec {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "llmModelUserChosen"),
           let file = defaults.string(forKey: "llmModelFile"),
           let url = defaults.string(forKey: "llmModelURL"), !file.isEmpty {
            return LLMSpec(file: file, url: url,
                           title: defaults.string(forKey: "llmModelTitle") ?? file)
        }
        return LLMCatalog.defaultModel().spec
    }
}

struct ChatTurn: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let text: String
}

/// Накопитель токенов; обращения сериализованы внутри актора LLMRuntime.
private final class TokenBuffer: @unchecked Sendable {
    var text = ""
}

/// Потокобезопасный сбор stderr дочернего процесса (для диагностики сбоев).
private final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    func tail(_ maxChars: Int = 300) -> String {
        lock.lock(); defer { lock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(maxChars))
    }
}

actor LLMRuntime {
    static let shared = LLMRuntime()

    private var server: Process?
    private var port: Int = 0
    private var loadedModel: String?
    private var lastUse = Date()
    private var idleWatcher: Task<Void, Never>?

    static var modelURL: URL {
        Transcriber.modelsDir.appendingPathComponent(LLMSpec.current.file)
    }

    static func serverBinary() -> URL? {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "llama-server"),
           FileManager.default.isExecutableFile(atPath: aux.path) {
            return aux
        }
        for path in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Генерация (OpenAI-совместимый стриминг)

    func generate(
        turns: [ChatTurn],
        onToken: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let port = try await ensureServer(onStatus: onStatus)
        lastUse = Date()
        onStatus("думаю…")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let body: [String: Any] = [
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
            "stream": true,
            "temperature": 0.3,
            "top_p": 0.9,
            "max_tokens": 2048,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetRecError("Локальная модель вернула ошибку. Попробуйте ещё раз.")
        }

        struct Delta: Decodable {
            struct Choice: Decodable {
                struct Content: Decodable { let content: String? }
                let delta: Content?
            }
            let choices: [Choice]
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            if Task.isCancelled { break }
            if let data = payload.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(Delta.self, from: data),
               let token = chunk.choices.first?.delta?.content, !token.isEmpty {
                onToken(token)
            }
        }
        lastUse = Date()
        scheduleIdleShutdown()
    }

    /// Полный ответ одним куском (для фоновых задач вроде авто-саммари).
    func complete(
        turns: [ChatTurn],
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let buffer = TokenBuffer()
        try await generate(turns: turns, onToken: { buffer.text += $0 }, onStatus: onStatus)
        return buffer.text
    }

    /// Останавливает llama-server — освобождает ~6 ГБ памяти.
    func shutdown() {
        server?.terminate()
        server = nil
        loadedModel = nil
    }

    // MARK: - Сервер

    private func ensureServer(onStatus: @escaping @Sendable (String) -> Void) async throws -> Int {
        let spec = LLMSpec.current
        if let server, server.isRunning, loadedModel == spec.file {
            return port
        }
        shutdown()

        guard let binary = Self.serverBinary() else {
            throw MeetRecError("Не найден llama-server. Переустановите MeetRec.")
        }
        let modelPath = Self.modelURL
        if !FileManager.default.fileExists(atPath: modelPath.path) {
            // Разовое подтверждение перед первой загрузкой модели (может быть ~9 ГБ).
            if let model = LLMCatalog.model(file: spec.file) {
                let ok = await MainActor.run { AppState.confirmModelDownload(model) }
                guard ok else { throw MeetRecError("Загрузка модели отменена. Выбрать модель полегче можно в «Модель ИИ» (шестерёнка).") }
            }
            let sizeHint = LLMCatalog.model(file: spec.file).map { String(format: "~%.1f ГБ", $0.fileGB) } ?? "несколько ГБ"
            onStatus("скачивание модели \(spec.title) (\(sizeHint))…")
            guard let url = URL(string: spec.url) else {
                throw MeetRecError("Некорректный адрес модели.")
            }
            try await Downloader.fetch(from: url, to: modelPath, label: "модель \(spec.title)", progress: onStatus)
        }

        onStatus("загрузка модели в память…")
        Log.info("LLM: запуск llama-server, модель \(spec.file)")
        let chosenPort = Int.random(in: 49500..<64000)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelPath.path,
            "--host", "127.0.0.1",
            "--port", "\(chosenPort)",
            "-c", "32768",       // контекст 32К (нативный для Qwen 2.5) — вмещает длинные транскрипты
            "-ngl", "99",        // все слои на GPU (Metal)
            "--no-webui",
        ]
        // stdout сервера не читаем — направляем в /dev/null, чтобы пайп не переполнялся.
        process.standardOutput = FileHandle.nullDevice
        // Собираем stderr llama-server — в нём видна реальная причина сбоя (OOM и т.п.).
        let errPipe = Pipe()
        process.standardError = errPipe
        let errLog = ServerLog()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                errLog.append(text)
            }
        }
        try process.run()
        server = process
        port = chosenPort
        loadedModel = spec.file

        // Ждём готовности (холодная загрузка 7B может занять до ~3 минут при нагрузке).
        let start = Date()
        let health = URL(string: "http://127.0.0.1:\(chosenPort)/health")!
        for _ in 0..<360 {
            if !process.isRunning {
                errPipe.fileHandleForReading.readabilityHandler = nil
                let tail = errLog.tail()
                Log.error("LLM: llama-server упал при запуске. stderr: \(tail)")
                throw MeetRecError("Не удалось загрузить локальную модель — возможно, не хватило памяти. \(tail)")
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                // Сервер готов и будет работать дальше — продолжаем дренировать stderr
                // (иначе за долгую сессию пайп переполнится), но уже без накопления в память.
                errPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
                Log.info(String(format: "LLM: модель загружена за %.1f с", Date().timeIntervalSince(start)))
                return chosenPort
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        Log.error("LLM: модель не загрузилась за 180 с. stderr: \(errLog.tail())")
        shutdown()
        throw MeetRecError("Модель не загрузилась за отведённое время (180 с).")
    }

    /// Гасим сервер после 5 минут простоя.
    private func scheduleIdleShutdown() {
        idleWatcher?.cancel()
        idleWatcher = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() {
        if Date().timeIntervalSince(lastUse) >= 5 * 60 {
            shutdown()
        }
    }
}
