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

    /// Модель VAD (детектор речи) — вшита в приложение, убирает галлюцинации на паузах.
    static func vadModel() -> URL? {
        if let url = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let fallback = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Язык распознавания: «auto» или код (ru/en…). Хранится в настройках.
    static var language: String {
        UserDefaults.standard.string(forKey: "whisperLanguage") ?? "auto"
    }

    private let processLock = NSLock()
    private var running: [Process] = []

    func transcribe(
        audio: URL, header: String? = nil, diarize: Bool = false,
        tracks: [String: URL] = [:], voices: Bool = false,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        defer { for url in tracks.values { try? FileManager.default.removeItem(at: url) } }
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
            {
                var args = ["-m", Self.modelURL.path, "-f", wav.path,
                            "-l", Self.language, "-t", "8", "-fa",
                            "-oj", "-of", base.path, "--print-progress"]
                // VAD режет тишину и убирает повторы-галлюцинации на паузах.
                if let vad = Self.vadModel() {
                    args += ["--vad", "--vad-model", vad.path]
                }
                args += Glossary.whisperArguments
                return args
            }()
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
        var parsed = try JSONDecoder().decode(WhisperOutput.self, from: data)
        parsed.transcription = Self.filtered(parsed)

        var speakers: [DiarizationService.SpeakerSegment] = []
        if diarize {
            do {
                speakers = try await DiarizationService.shared.diarize(wav: wav, progress: progress)
            } catch {
                // Диаризация — необязательное улучшение: при сбое сохраняем обычный транскрипт.
                speakers = []
            }
            if !speakers.isEmpty {
                speakers = await nameSpeakers(
                    speakers, meeting: audio.deletingPathExtension().lastPathComponent,
                    mixed: wav, tracks: tracks, voices: voices, progress: progress)
            }
        }

        let markdown = speakers.isEmpty
            ? renderMarkdown(audio: audio, segments: parsed.transcription, header: header)
            : renderDialog(audio: audio, segments: parsed.transcription, speakers: speakers, header: header)
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
        struct LLMModel: Decodable {
            let file: String
            let title: String?
            let url: String
        }
        let recommended: Model
        let llm: LLMModel?
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
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        // Рекомендованную с сервера LLM применяем только если пользователь не
        // выбрал модель сам (иначе перетёрли бы его выбор из настроек).
        if let llm = manifest.llm, !UserDefaults.standard.bool(forKey: "llmModelUserChosen") {
            UserDefaults.standard.set(llm.file, forKey: "llmModelFile")
            UserDefaults.standard.set(llm.url, forKey: "llmModelURL")
            UserDefaults.standard.set(llm.title ?? llm.file, forKey: "llmModelTitle")
        }
        let recommended = manifest.recommended
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
        try await Downloader.fetch(from: sourceURL, to: dest, label: "модель", progress: progress)

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
        try await Downloader.fetch(
            from: Self.modelDownloadURL, to: dest, label: "модель", progress: progress)
    }

    // MARK: - Запуск процессов

    private func run(
        _ tool: URL, _ args: [String],
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        // stdout ОБЯЗАТЕЛЬНО дренируем: whisper-cli печатает туда сегменты по мере
        // распознавания. Если не читать — буфер пайпа (~64 КБ) переполняется, запись
        // блокируется и процесс зависает (проявлялось на записях >1 часа ~ на 30%).
        let outPipe = Pipe()
        process.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData // читаем и отбрасываем — результат берём из JSON-файла
        }
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
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: finished.terminationStatus)
            }
        }
    }

    // MARK: - Имена говорящих

    /// «Я» по дорожке микрофона и имена из библиотеки голосов. Любой сбой здесь не
    /// мешает транскрипту: возвращаются исходные метки.
    private func nameSpeakers(
        _ speakers: [DiarizationService.SpeakerSegment], meeting: String,
        mixed: URL, tracks: [String: URL], voices: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async -> [DiarizationService.SpeakerSegment] {
        let service = DiarizationService.shared
        var audio: [String: [Float]] = [:]
        for (name, url) in tracks {
            if let samples = try? service.loadSamples(wav: url) { audio[name] = samples }
        }
        if audio.count < 2 { audio = [:] } // нужна пара «микрофон + звонок»
        var lines = speakers.map { VoiceLine(start: $0.start, end: $0.end, speaker: $0.speaker) }
        var renames: [String: String] = [:]

        // «Я»: метка, чьи реплики громче всего на микрофоне (больше всех секунд речи).
        if audio["mic"] != nil, audio["call"] != nil {
            let homes = VoicePrints.homeTracks(tracks: audio, lines: lines)
            let mine = homes.filter { $0.value == "mic" }.map(\.key)
            let talk = Dictionary(grouping: lines, by: \.speaker).mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
            if let me = mine.max(by: { (talk[$0] ?? 0) < (talk[$1] ?? 0) }) {
                renames[me] = LiveCaptioner.meSpeaker
            }
        }
        for i in lines.indices { lines[i].speaker = renames[lines[i].speaker] ?? lines[i].speaker }

        if voices {
            do {
                progress("узнаю голоса…")
                if audio.isEmpty { audio = ["mix": try service.loadSamples(wav: mixed)] }
                let embed = try await service.embedder(progress: progress)
                var prints = VoicePrints.compute(tracks: audio, lines: lines, embed: embed)
                let taken = Set(lines.map(\.speaker).filter { !VoicePrints.isGeneric($0) })
                let found = await VoiceLibrary.shared.match(prints, taken: taken)
                var record = MeetingVoices()
                for (label, match) in found {
                    prints[match.name] = prints.removeValue(forKey: label)
                    record.speakers[match.name] = MeetingVoices.Speaker(recognized: match)
                }
                // Итоговое имя каждой исходной метки диаризации: после «Я» и узнавания.
                for original in Set(speakers.map(\.speaker)) {
                    let current = renames[original] ?? original
                    if let match = found[current] { renames[original] = match.name }
                }
                for (label, print) in prints { record.speakers[label, default: .init()].print = print }
                await VoiceLibrary.shared.remember(meeting: meeting, prints: prints)
                await VoiceLibrary.shared.saveMeeting(meeting, record)
                if !found.isEmpty {
                    Log.info("Голоса: узнано \(found.count) · " + found.values.map { String(format: "%.2f", $0.score) }.joined(separator: ", "))
                }
            } catch {
                Log.error("Голоса: \(error.localizedDescription)")
            }
        }

        guard !renames.isEmpty else { return speakers }
        return speakers.map {
            DiarizationService.SpeakerSegment(speaker: renames[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end)
        }
    }

    // MARK: - Формат результата

    private struct WhisperOutput: Decodable {
        struct Result: Decodable { let language: String? }
        struct Segment: Decodable {
            struct Offsets: Decodable {
                let from: Int
                let to: Int
            }
            let offsets: Offsets
            let text: String
        }
        let result: Result?
        var transcription: [Segment]
    }

    /// Убирает титры-галлюцинации и петли декодера (фильтры живых субтитров в бережном режиме).
    private static func filtered(_ output: WhisperOutput) -> [WhisperOutput.Segment] {
        let segments = output.transcription.map {
            LiveSegment(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000,
                        text: $0.text, lang: "")
        }
        let duration = (segments.map(\.end).max() ?? 0) + 1
        let clean = CaptionFilters.clean(
            segments, duration: duration, mode: .transcript, lang: output.result?.language ?? "")
        if clean.count < segments.count {
            Log.info("Расшифровка: убрано сегментов-галлюцинаций \(segments.count - clean.count) из \(segments.count)")
        }
        return clean.map {
            WhisperOutput.Segment(
                offsets: .init(from: Int(($0.start * 1000).rounded()), to: Int(($0.end * 1000).rounded())),
                text: $0.text)
        }
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

    /// Транскрипт в виде диалога: реплики сгруппированы по говорящим.
    private func renderDialog(
        audio: URL,
        segments: [WhisperOutput.Segment],
        speakers: [DiarizationService.SpeakerSegment],
        header: String?
    ) -> String {
        var lines = ["# \(audio.deletingPathExtension().lastPathComponent)", ""]
        if let header, !header.isEmpty {
            lines.append(header)
            lines.append("")
        }

        var currentSpeaker: String?
        var paragraph: [String] = []
        var paragraphStart = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            let label = currentSpeaker ?? "Спикер ?"
            lines.append("**\(label) [\(timestamp(paragraphStart))]:** \(paragraph.joined(separator: " "))")
            lines.append("")
            paragraph = []
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = dominantSpeaker(
                fromMs: segment.offsets.from, toMs: segment.offsets.to, in: speakers)
                ?? currentSpeaker
            if speaker != currentSpeaker {
                flush()
                currentSpeaker = speaker
                paragraphStart = segment.offsets.from
            }
            if paragraph.isEmpty {
                paragraphStart = segment.offsets.from
            }
            paragraph.append(text)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Говорящий с максимальным пересечением по времени с данным сегментом.
    private func dominantSpeaker(
        fromMs: Int, toMs: Int, in speakers: [DiarizationService.SpeakerSegment]
    ) -> String? {
        let from = Double(fromMs) / 1000, to = Double(toMs) / 1000
        var best: (speaker: String, overlap: Double)?
        for speaker in speakers {
            let overlap = min(to, speaker.end) - max(from, speaker.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (speaker.speaker, overlap)
            }
        }
        return best?.speaker
    }

    private func timestamp(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
