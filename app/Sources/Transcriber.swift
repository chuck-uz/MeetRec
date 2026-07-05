// Локальная транскрибация через whisper.cpp (модель large-v3-turbo, Metal).
import Foundation

final class Transcriber {
    static let shared = Transcriber()

    /// Список рекомендованных моделей — обновляется в репозитории проекта,
    /// приложение сверяется с ним и само скачивает новую модель.
    static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/chuck-uz/MeetRec/main/models.json")!

    static var modelName: String {
        get { UserDefaults.standard.string(forKey: "whisperModelName") ?? "ggml-large-v3-turbo.bin" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModelName") }
    }

    static var modelTitle: String {
        get { UserDefaults.standard.string(forKey: "whisperModelTitle") ?? "Whisper large-v3-turbo" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModelTitle") }
    }

    static var modelDownloadURL: URL {
        UserDefaults.standard.string(forKey: "whisperModelURL").flatMap(URL.init(string:))
            ?? URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    }

    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/models")
    }

    static var modelURL: URL {
        modelsDir.appendingPathComponent(modelName)
    }

    static func transcriptURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("md")
    }

    /// whisper-cli: сначала копия внутри приложения, потом Homebrew.
    static func whisperCLI() -> URL? {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
           FileManager.default.isExecutableFile(atPath: aux.path) {
            return aux
        }
        for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private let processLock = NSLock()
    private var running: [Process] = []

    func transcribe(
        audio: URL, header: String? = nil,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard let cli = Self.whisperCLI() else {
            throw MeetRecError("Не найден whisper-cli. Переустановите MeetRec или выполните: brew install whisper-cpp")
        }
        try await ensureModel(progress: progress)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetrec-\(UUID().uuidString)")
        let wav = base.appendingPathExtension("wav")
        let json = base.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: json)
        }

        progress("подготовка…")
        let convertStatus = try await run(
            URL(fileURLWithPath: "/usr/bin/afconvert"),
            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path])
        guard convertStatus == 0 else {
            throw MeetRecError("Не удалось подготовить аудио для распознавания.")
        }

        progress("распознавание…")
        let status = try await run(
            cli,
            ["-m", Self.modelURL.path, "-f", wav.path,
             "-l", "auto", "-t", "8", "-fa",
             "-oj", "-of", base.path, "--print-progress"]
        ) { chunk in
            if let match = chunk.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression) {
                let percent = chunk[match].filter(\.isNumber)
                progress("распознавание \(percent)%")
            }
        }
        guard status == 0 else {
            throw MeetRecError("Ошибка распознавания (код \(status)).")
        }

        let data = try Data(contentsOf: json)
        let parsed = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let markdown = renderMarkdown(audio: audio, segments: parsed.transcription, header: header)
        let out = Self.transcriptURL(for: audio)
        try markdown.data(using: .utf8)!.write(to: out)
        return out
    }

    func cancelAll() {
        processLock.lock()
        defer { processLock.unlock() }
        for process in running where process.isRunning {
            process.terminate()
        }
        running.removeAll()
    }

    // MARK: - Модель

    private struct ModelManifest: Decodable {
        struct Model: Decodable {
            let name: String
            let title: String?
            let url: String
        }
        let recommended: Model
    }

    /// Сверяется с манифестом в репозитории; если рекомендована другая модель —
    /// скачивает её и переключается, старую удаляет. Возвращает true при обновлении.
    @discardableResult
    func updateModelIfNeeded(progress: @escaping @Sendable (String) -> Void) async throws -> Bool {
        let request = URLRequest(
            url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetRecError("Манифест моделей недоступен.")
        }
        let recommended = try JSONDecoder().decode(ModelManifest.self, from: data).recommended
        guard let sourceURL = URL(string: recommended.url) else {
            throw MeetRecError("Некорректный адрес модели в манифесте.")
        }
        let alreadyCurrent = recommended.name == Self.modelName
            && FileManager.default.fileExists(atPath: Self.modelURL.path)
        if alreadyCurrent {
            // Название модели могло не меняться, а заголовок — уточниться.
            if let title = recommended.title { Self.modelTitle = title }
            return false
        }

        progress("обновление модели…")
        let dest = Self.modelsDir.appendingPathComponent(recommended.name)
        try await download(from: sourceURL, to: dest, progress: progress)

        let oldName = Self.modelName
        Self.modelName = recommended.name
        Self.modelTitle = recommended.title ?? recommended.name
        UserDefaults.standard.set(recommended.url, forKey: "whisperModelURL")
        if oldName != recommended.name {
            try? FileManager.default.removeItem(at: Self.modelsDir.appendingPathComponent(oldName))
        }
        return true
    }

    private func ensureModel(progress: @escaping @Sendable (String) -> Void) async throws {
        let dest = Self.modelURL
        if FileManager.default.fileExists(atPath: dest.path) { return }
        progress("загрузка модели…")
        try await download(from: Self.modelDownloadURL, to: dest, progress: progress)
    }

    private func download(
        from source: URL, to dest: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetRecError("Не удалось скачать модель распознавания. Проверьте интернет.")
        }
        let expected = response.expectedContentLength
        let tmp = dest.appendingPathExtension("download")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(4 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (4 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    progress("модель \(Int(Double(written) / Double(expected) * 100))%")
                }
            }
        }
        try handle.write(contentsOf: buffer)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: - Запуск процессов

    private func run(
        _ tool: URL, _ args: [String],
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        if let onStderr {
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    onStderr(text)
                }
            }
        }
        processLock.lock()
        running.append(process)
        processLock.unlock()
        try process.run()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { finished in
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: finished.terminationStatus)
            }
        }
    }

    // MARK: - Формат результата

    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable {
                let from: Int
                let to: Int
            }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }

    private func renderMarkdown(audio: URL, segments: [WhisperOutput.Segment], header: String? = nil) -> String {
        var lines = ["# \(audio.deletingPathExtension().lastPathComponent)", ""]
        if let header, !header.isEmpty {
            lines.append(header)
            lines.append("")
        }
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("**[\(timestamp(segment.offsets.from))]** \(text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func timestamp(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
