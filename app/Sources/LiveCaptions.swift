// Живые субтитры с переводом во время записи.
//
// Звук звонка и микрофона приходит из RecorderEngine (ScreenCaptureKit), копится по дорожкам
// и раз в секунду режется на окна 6–20 с по паузам. Окно распознаёт whisper-cli (та же
// модель, что и для итоговой расшифровки; на тёплом кэше ~1,7 с на окно). Реплики на
// иностранном языке переводятся локальной LLM (llama-server) отдельной очередью, чтобы
// медленный перевод не задерживал текст. Логика перенесена из meetvoice-kit (live.py).
import CoreMedia
import Foundation

struct CaptionEntry: Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    let speaker: String
    let isMe: Bool
    let text: String
    let lang: String
    /// Язык перевода; пусто — реплику не переводим.
    let target: String
    var translation: String?

    var waitingTranslation: Bool { !target.isEmpty && translation == nil }
    /// Перевод, который есть смысл показать.
    var shownTranslation: String? {
        guard let translation, !translation.isEmpty, translation != "—" else { return nil }
        return translation
    }
}

@MainActor
final class LiveCaptioner: ObservableObject {
    static let meSpeaker = "Я"
    static let otherSpeaker = "Собеседник"
    nonisolated static let fileSuffix = " — субтитры"

    @Published private(set) var entries: [CaptionEntry] = []
    @Published private(set) var status = "слушаю…"
    @Published private(set) var active = true
    @Published private(set) var lastError: String?

    /// Родной язык: на нём реплики не переводятся, остальные переводятся на него.
    let native: String
    let translationAvailable: Bool

    nonisolated let callBuffer = LiveTrackBuffer()
    nonisolated let micBuffer = LiveTrackBuffer()

    private var worker: LiveWorker?
    private var loop: Task<Void, Never>?
    private var translations: Task<Void, Never>?
    private var queue: AsyncStream<Int>.Continuation?

    init(native: String) {
        self.native = native
        translationAvailable = Hardware.supportsChat
            && LLMRuntime.serverBinary() != nil
            && FileManager.default.fileExists(atPath: LLMRuntime.modelURL.path)
    }

    /// Вызывается на очереди захвата для каждого аудиобуфера.
    nonisolated func push(_ buffer: CMSampleBuffer, mic: Bool) {
        (mic ? micBuffer : callBuffer).push(buffer)
    }

    nonisolated static func captionsURL(forAudio audio: URL) -> URL {
        let base = audio.deletingPathExtension().lastPathComponent
        return audio.deletingLastPathComponent().appendingPathComponent(base + fileSuffix + ".md")
    }

    nonisolated static func isCaptions(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix(fileSuffix)
    }

    func start() {
        guard let cli = Transcriber.whisperCLI(),
              FileManager.default.fileExists(atPath: Transcriber.modelURL.path) else {
            active = false
            status = "субтитры недоступны: модель Whisper ещё не скачана"
            return
        }
        let worker = LiveWorker(
            whisper: cli, model: Transcriber.modelURL, vad: Transcriber.vadModel(),
            call: callBuffer, mic: micBuffer, native: native)
        worker.owner = self
        self.worker = worker
        loop = Task.detached(priority: .userInitiated) { await worker.run() }

        if translationAvailable {
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            queue = continuation
            translations = Task { [weak self] in
                // Прогрев: иначе первые переводы опоздают на время загрузки модели.
                _ = try? await LLMRuntime.shared.complete(
                    turns: [ChatTurn(role: .user, text: "Ответь одним словом: готов?")],
                    temperature: 0, maxTokens: 4, onStatus: { _ in })
                for await index in stream {
                    guard let self else { return }
                    await self.translate(index)
                }
            }
        }
        status = translationAvailable ? "слушаю…" : "слушаю… (перевод выключен: нет локальной модели ИИ)"
        Log.info("Живые субтитры: старт · родной язык \(native) · перевод=\(translationAvailable)")
    }

    /// Останавливает распознавание (дораспознаёт хвост), ждёт переводы и сохраняет
    /// субтитры рядом с записью.
    func finish(audioURL: URL?) async {
        guard active else { return }
        status = "дораспознаю конец…"
        worker?.requestStop()
        await loop?.value
        let deadline = Date().addingTimeInterval(10)
        while entries.contains(where: \.waitingTranslation), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        queue?.finish()
        translations?.cancel()
        active = false
        status = "запись остановлена"
        if let audioURL, !entries.isEmpty {
            save(next: audioURL)
        }
        Log.info("Живые субтитры: стоп · реплик \(entries.count)")
    }

    // MARK: - Реплики

    func target(for lang: String) -> String {
        guard translationAvailable, !lang.isEmpty, lang != native else { return "" }
        return native
    }

    fileprivate func append(_ segments: [LiveSegment], windowStart: Double, isMe: Bool) {
        for segment in segments {
            let entry = CaptionEntry(
                id: entries.count,
                start: windowStart + segment.start, end: windowStart + segment.end,
                speaker: isMe ? Self.meSpeaker : Self.otherSpeaker, isMe: isMe,
                text: segment.text, lang: segment.lang, target: target(for: segment.lang))
            entries.append(entry)
            if !entry.target.isEmpty { queue?.yield(entry.id) }
        }
    }

    fileprivate func report(error: String) {
        lastError = error
        Log.error("Живые субтитры: \(error)")
    }

    private func translate(_ index: Int) async {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        guard !entry.target.isEmpty else { return }
        let context = entries[max(0, index - 4)..<index].map(\.text).joined(separator: "\n")
        let prompt = Self.translationPrompt(target: entry.target, source: entry.lang, context: context)
        do {
            let raw = try await LLMRuntime.shared.complete(
                turns: [ChatTurn(role: .system, text: prompt), ChatTurn(role: .user, text: entry.text)],
                temperature: 0.2, maxTokens: 300, onStatus: { _ in })
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
            // Язык окна мог определиться неверно (русское «Хорошо» после английской фразы):
            // перевод, совпавший с оригиналом, не показываем.
            entries[index].translation =
                CaptionFilters.norm(text) == CaptionFilters.norm(entry.text) ? "" : text
        } catch {
            report(error: "перевод: \(error.localizedDescription)")
            entries[index].translation = "—"
        }
    }

    // MARK: - Перевод

    static let languageNames = [
        "ru": "русский", "en": "English", "uk": "українська", "kk": "қазақша", "uz": "o'zbekcha",
        "de": "Deutsch", "fr": "français", "es": "español", "tr": "Türkçe",
    ]
    static let sourceNames = [
        "en": "английский", "uz": "узбекский", "de": "немецкий", "fr": "французский", "es": "испанский",
        "tr": "турецкий", "kk": "казахский", "uk": "украинский", "zh": "китайский", "it": "итальянский",
        "pl": "польский", "ru": "русский",
    ]

    /// Живые реплики — фрагменты с ошибками распознавания: даём контекст и говорим,
    /// что текст распознан автоматически. Фразу «если уже на этом языке — верни как есть»
    /// не добавляем: неуверенная модель возвращала исходник без перевода.
    static func translationPrompt(target: String, source: String, context: String) -> String {
        var prompt = "Переведи реплику из живой расшифровки разговора на язык: \(languageNames[target] ?? target). "
            + "Верни только перевод, без пояснений и кавычек. Имена, названия продуктов и команды не переводи."
        let sourceName = sourceNames[source] ?? source
        prompt += " Исходный язык: \(sourceName); текст распознан автоматически и может содержать ошибки — "
            + "переводи по смыслу, исходный текст не повторяй."
        if !context.isEmpty {
            prompt += " Предыдущие реплики (для понимания, их не переводи):\n\(context)"
        }
        return prompt
    }

    // MARK: - Файл субтитров

    private func save(next audio: URL) {
        var lines = ["# Субтитры — \(audio.deletingPathExtension().lastPathComponent)", ""]
        for entry in entries {
            lines.append("**[\(Self.clock(entry.start))] \(entry.speaker):** \(entry.text)")
            if let translation = entry.shownTranslation {
                lines.append("> \(translation)")
            }
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").data(using: .utf8)!.write(to: Self.captionsURL(forAudio: audio))
        } catch {
            report(error: "не удалось сохранить субтитры: \(error.localizedDescription)")
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Распознавание окон (фоновый поток)

private final class LiveWorker: @unchecked Sendable {
    static let minWindowSec = 6.0
    static let maxWindowSec = 20.0
    static let minCutSec = 3.0
    static let silenceRMS: Float = 0.004
    static let historySec = 60.0
    static let echoMinSec = 5.0

    private final class TrackState {
        let source: LiveTrackBuffer
        let isMe: Bool
        var buffer: [Float] = []
        var bufferStart = 0.0
        var history: [Float] = []
        var historyStart = 0.0

        init(source: LiveTrackBuffer, isMe: Bool) {
            self.source = source
            self.isMe = isMe
        }

        var historyEnd: Double { historyStart + Double(history.count) / LiveDSP.rate }

        func pull() {
            let new = source.drain()
            guard !new.isEmpty else { return }
            buffer += new
            history += new
            let extra = history.count - Int(LiveWorker.historySec * LiveDSP.rate)
            if extra > 0 {
                history.removeFirst(extra)
                historyStart += Double(extra) / LiveDSP.rate
            }
        }

        func span(_ a: Double, _ b: Double) -> [Float] {
            let i = max(0, min(history.count, Int((a - historyStart) * LiveDSP.rate)))
            let j = max(i, min(history.count, Int((b - historyStart) * LiveDSP.rate)))
            return Array(history[i..<j])
        }

        func takeWindow(flush: Bool) -> (Double, [Float])? {
            let duration = Double(buffer.count) / LiveDSP.rate
            if duration < (flush ? 0.5 : LiveWorker.minWindowSec) { return nil }
            let cut: Int
            if flush {
                cut = buffer.count
            } else if duration >= LiveWorker.maxWindowSec {
                cut = LiveDSP.quietCut(buffer[0..<Int(LiveWorker.maxWindowSec * LiveDSP.rate)],
                                       minCutSec: LiveWorker.minCutSec)
            } else {
                cut = LiveDSP.quietCut(buffer[...], minCutSec: LiveWorker.minCutSec)
                if cut < Int(LiveWorker.minCutSec * LiveDSP.rate) { return nil }
            }
            let window = Array(buffer[0..<cut])
            let start = bufferStart
            buffer.removeFirst(cut)
            bufferStart += Double(cut) / LiveDSP.rate
            return (start, window)
        }
    }

    weak var owner: LiveCaptioner?
    private let whisper: URL
    private let model: URL
    private let vad: URL?
    private let call: TrackState
    private let mic: TrackState
    private let micLanguages: Set<String>
    private let lock = NSLock()
    private var stopRequested = false

    init(whisper: URL, model: URL, vad: URL?, call: LiveTrackBuffer, mic: LiveTrackBuffer, native: String) {
        self.whisper = whisper
        self.model = model
        self.vad = vad
        self.call = TrackState(source: call, isMe: false)
        self.mic = TrackState(source: mic, isMe: true)
        // В микрофоне выживают только родной язык и английский: остальное — эхо и шум.
        micLanguages = ["ru", "en", "", native]
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private var stopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func run() async {
        while true {
            let flush = stopping
            if !flush { try? await Task.sleep(for: .seconds(1)) }
            for track in [call, mic] {
                track.pull()
                while let (start, window) = track.takeWindow(flush: flush) {
                    await recognize(track, start: start, audio: window)
                }
            }
            if flush { return }
        }
    }

    private func recognize(_ track: TrackState, start: Double, audio input: [Float]) async {
        guard LiveDSP.rms(input[...]) >= Self.silenceRMS else { return }
        var audio = input
        if track.isMe {
            guard let clean = echoFree(start: start, audio: input) else { return }
            audio = clean
        }
        do {
            let duration = Double(audio.count) / LiveDSP.rate
            let segments = CaptionFilters.clean(try await transcribe(audio), duration: duration)
                .filter { !track.isMe || micLanguages.contains($0.lang) }
            guard !segments.isEmpty else { return }
            await owner?.append(segments, windowStart: start, isMe: track.isMe)
        } catch {
            await owner?.report(error: error.localizedDescription)
        }
    }

    /// Вырезает из окна микрофона звук звонка, услышанный через динамики.
    /// nil — в окне не осталось ничего, кроме эха.
    private func echoFree(start: Double, audio: [Float]) -> [Float]? {
        let a = max(mic.historyStart, call.historyStart)
        let b = min(mic.historyEnd, call.historyEnd)
        guard b - a >= Self.echoMinSec,
              let lag = LiveDSP.crosstalkLag(mic: mic.span(a, b), ref: call.span(a, b), minSec: Self.echoMinSec)
        else { return audio } // наушники: микрофон звонок не слышит
        let regions = LiveDSP.speechRegions(audio)
        let reference = call.span(start, start + Double(audio.count) / LiveDSP.rate)
        let kept = LiveDSP.dropCrosstalk(regions: regions, mic: audio, ref: reference, lag: lag)
        guard !kept.isEmpty else { return nil }
        if kept.count == regions.count, zip(kept, regions).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) {
            return audio
        }
        var clean = [Float](repeating: 0, count: audio.count)
        for (x, y) in kept {
            let i = max(0, Int(x * LiveDSP.rate)), j = min(audio.count, Int(y * LiveDSP.rate))
            if i < j { clean.replaceSubrange(i..<j, with: audio[i..<j]) }
        }
        return clean
    }

    // MARK: whisper-cli

    private struct Output: Decodable {
        struct Result: Decodable { let language: String? }
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let result: Result?
        let transcription: [Segment]
    }

    private func transcribe(_ audio: [Float]) async throws -> [LiveSegment] {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetrec-live-\(UUID().uuidString)")
        let wav = base.appendingPathExtension("wav")
        let json = base.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: json)
        }
        try LiveDSP.wavData(audio).write(to: wav)
        // -l auto: язык определяется на каждое окно, иначе не поймём, что переводить.
        // -mc 0: без опоры на предыдущий текст — одна галлюцинация не отравляет остальное.
        var args = ["-m", model.path, "-f", wav.path, "-l", "auto", "-t", "8", "-fa",
                    "-nf", "-mc", "0", "-oj", "-of", base.path, "-np"]
        if let vad { args += ["--vad", "--vad-model", vad.path] }
        let status = try await Self.run(whisper, args)
        guard status == 0 else { throw MeetRecError("whisper-cli завершился с кодом \(status)") }
        let output = try JSONDecoder().decode(Output.self, from: Data(contentsOf: json))
        let lang = output.result?.language ?? ""
        return output.transcription.map {
            LiveSegment(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000,
                        text: $0.text, lang: lang)
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
