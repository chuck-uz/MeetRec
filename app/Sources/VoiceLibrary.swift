// Библиотека голосов: спикеры, названные в одной встрече, узнаются по голосу в следующих.
//
// Отпечаток — эмбеддинг WeSpeaker (FluidAudio, 256 чисел), усреднённый по самым длинным
// «чистым» репликам метки. Хранятся только числа, без звука, локально в Application Support.
// Вклад каждой встречи хранится отдельно: переименование спикера заменяет его целиком.
// Логика перенесена из meetvoice-kit (voices.py); пороги — VoiceThresholds.
import Foundation

enum VoiceThresholds {
    static let embedMaxSec = 10.0   // окно модели; длинная реплика режется до середины
    static let minLineSec = 1.5
    static let linesPerPrint = 12
    static let minPrintSec = 8.0    // меньше чистой речи — отпечаток похож на всех
    static let loudDB = 10.0        // реплика не тише речи своей дорожки больше чем на столько…
    static let otherQuietDB = 12.0  // …а другие дорожки минимум на столько тише своей речи
    /// Минимальное сходство с голосом из библиотеки (калибровка — ARCHITECTURE.md, 5.10).
    static let match: Float = 0.62
    /// Отрыв от второго кандидата: два похожих голоса не получают имя.
    static let margin: Float = 0.08
}

struct VoiceLine {
    let start: Double
    let end: Double
    var speaker: String
}

struct VoicePrint: Codable, Equatable {
    var emb: [Float]
    var sec: Double
}

enum VoiceMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = dot(v, v).squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Громкость отрезка: 90-й перцентиль RMS по 30 мс, дБ.
    static func levelDB(_ audio: [Float], _ a: Double, _ b: Double) -> Double {
        let i = max(0, Int(a * 16_000)), j = min(audio.count, Int(b * 16_000))
        let frame = 480
        let frames = (j - i) / frame
        guard frames > 0 else { return -120 }
        var rms = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            rms[f] = Double(LiveDSP.rms(audio[(i + f * frame)..<(i + (f + 1) * frame)]))
        }
        rms.sort()
        let position = 0.9 * Double(frames - 1)
        let low = Int(position), high = min(low + 1, frames - 1)
        let value = rms[low] + (rms[high] - rms[low]) * (position - Double(low))
        return 20 * log10(value + 1e-9)
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return -120 }
        let position = q * Double(sorted.count - 1)
        let low = Int(position), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}

enum VoicePrints {
    /// Общие метки, которые библиотека может заменить именем.
    static func isGeneric(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.range(
            of: #"^(Я|Me|Собеседник|Спикер|Speaker|Запись|Unknown)(\s+\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Дорожка, на которой живёт каждая метка: та, где её реплики выделяются сильнее.
    static func homeTracks(tracks: [String: [Float]], lines: [VoiceLine]) -> [String: String] {
        let usable = lines.filter { $0.end - $0.start >= VoiceThresholds.minLineSec }
        guard !tracks.isEmpty, !usable.isEmpty else { return [:] }
        let levels = tracks.mapValues { audio in usable.map { VoiceMath.levelDB(audio, $0.start, $0.end) } }
        let speech = levels.mapValues { VoiceMath.percentile($0, 0.75) }
        var votes: [String: [String: Int]] = [:]
        for (i, line) in usable.enumerated() {
            let loudest = tracks.keys.max { levels[$0]![i] - speech[$0]! < levels[$1]![i] - speech[$1]! }!
            votes[line.speaker, default: [:]][loudest, default: 0] += 1
        }
        return votes.mapValues { $0.max { $0.value < $1.value }!.key }
    }

    /// {метка: отпечаток} для меток, у которых достаточно чистой речи.
    ///
    /// В отпечаток идут только реплики, где все остальные дорожки молчат: при
    /// одновременной речи микрофон слышит звонок из динамиков, и отпечаток смешивает двух
    /// людей (измерено в meetvoice: разные люди 0.69 со смешанными отпечатками, 0.2 с чистыми).
    static func compute(
        tracks: [String: [Float]], lines: [VoiceLine], embed: ([Float]) throws -> [Float]
    ) -> [String: VoicePrint] {
        let usable = lines.filter { $0.end - $0.start >= VoiceThresholds.minLineSec }
        guard !tracks.isEmpty, !usable.isEmpty else { return [:] }
        let levels = tracks.mapValues { audio in usable.map { VoiceMath.levelDB(audio, $0.start, $0.end) } }
        let speech = levels.mapValues { VoiceMath.percentile($0, 0.75) }
        let homes = homeTracks(tracks: tracks, lines: usable)

        var out: [String: VoicePrint] = [:]
        for label in Set(usable.map(\.speaker)) {
            guard let home = homes[label], let audio = tracks[home] else { continue }
            let indices = usable.indices.filter { usable[$0].speaker == label }
            let clean = indices.filter { i in
                levels[home]![i] >= speech[home]! - VoiceThresholds.loudDB
                    && tracks.keys.allSatisfy { $0 == home || levels[$0]![i] < speech[$0]! - VoiceThresholds.otherQuietDB }
            }
            .sorted { usable[$0].end - usable[$0].start > usable[$1].end - usable[$1].start }
            .prefix(VoiceThresholds.linesPerPrint)

            var sum = [Float](repeating: 0, count: 0)
            var seconds = 0.0
            for i in clean {
                var a = usable[i].start
                var b = min(usable[i].end, Double(audio.count) / 16_000)
                guard b - a >= 1 else { continue } // реплика за концом более короткой дорожки
                if b - a > VoiceThresholds.embedMaxSec {
                    let mid = (a + b) / 2
                    a = mid - VoiceThresholds.embedMaxSec / 2
                    b = mid + VoiceThresholds.embedMaxSec / 2
                }
                let slice = Array(audio[Int(a * 16_000)..<min(audio.count, Int(b * 16_000))])
                guard let vector = try? embed(slice), !vector.isEmpty else { continue }
                let weight = Float(b - a)
                if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
                for k in sum.indices { sum[k] += vector[k] * weight }
                seconds += b - a
            }
            guard seconds >= VoiceThresholds.minPrintSec else { continue }
            out[label] = VoicePrint(emb: VoiceMath.normalized(sum), sec: (seconds * 10).rounded() / 10)
        }
        return out
    }
}

/// Найденное по голосу имя для общей метки.
struct VoiceMatch: Codable, Equatable {
    let name: String
    let score: Float
}

/// Сведения о говорящих одной встречи (для переименования без повторной обработки звука).
struct MeetingVoices: Codable {
    struct Speaker: Codable {
        var print: VoicePrint?
        /// Имя дано по голосу автоматически (показываем пользователю, можно исправить).
        var recognized: VoiceMatch?
    }

    var speakers: [String: Speaker] = [:]
}

/// JSON-хранилище голосов: {"voices": {имя: {встреча: отпечаток}}}.
actor VoiceLibrary {
    static let shared = VoiceLibrary()

    private struct Entry: Codable {
        var emb: [Float]
        var sec: Double
        var ts: Double
    }

    private struct Store: Codable {
        var voices: [String: [String: Entry]] = [:]
    }

    struct Voice: Identifiable {
        let name: String
        let meetings: Int
        let seconds: Double
        var id: String { name }
    }

    static var directory: URL {
        Transcriber.modelsDir.deletingLastPathComponent().appendingPathComponent("voices")
    }

    private var libraryURL: URL { Self.directory.appendingPathComponent("voices.json") }

    private func meetingURL(_ meeting: String) -> URL {
        Self.directory.appendingPathComponent("meetings").appendingPathComponent(meeting + ".json")
    }

    // MARK: Хранилище

    private func load() -> Store {
        guard let data = try? Data(contentsOf: libraryURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }

    private func save(_ store: Store) {
        write(store, to: libraryURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("Голоса: не удалось сохранить \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func meeting(_ id: String) -> MeetingVoices? {
        guard let data = try? Data(contentsOf: meetingURL(id)) else { return nil }
        return try? JSONDecoder().decode(MeetingVoices.self, from: data)
    }

    func saveMeeting(_ id: String, _ voices: MeetingVoices) {
        write(voices, to: meetingURL(id))
    }

    // MARK: Список и управление

    func voices() -> [Voice] {
        load().voices.map { name, prints in
            Voice(name: name, meetings: prints.count, seconds: prints.values.reduce(0) { $0 + $1.sec })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func forget(_ name: String) -> Bool {
        var store = load()
        guard store.voices.removeValue(forKey: name) != nil else { return false }
        save(store)
        Log.info("Голоса: забыт голос (осталось \(store.voices.count))")
        return true
    }

    func forgetAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        Log.info("Голоса: библиотека удалена")
    }

    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        let name = String(new.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        var store = load()
        guard let prints = store.voices.removeValue(forKey: old), !name.isEmpty, !VoicePrints.isGeneric(name)
        else { return false }
        store.voices[name, default: [:]].merge(prints) { _, new in new }
        save(store)
        return true
    }

    // MARK: Узнавание

    private func centroids(_ store: Store) -> [String: [Float]] {
        store.voices.compactMapValues { prints in
            guard let first = prints.values.first else { return nil }
            var sum = [Float](repeating: 0, count: first.emb.count)
            for entry in prints.values {
                for k in sum.indices where k < entry.emb.count { sum[k] += entry.emb[k] * Float(entry.sec) }
            }
            return VoiceMath.normalized(sum)
        }
    }

    /// {общая метка: имя}: лучший голос не ниже порога и с отрывом от второго; каждое имя —
    /// одной метке (самой похожей); имена из `taken` (уже есть во встрече) не раздаются.
    func match(_ prints: [String: VoicePrint], taken: Set<String>) -> [String: VoiceMatch] {
        let cents = centroids(load())
        var candidates: [(Float, String, String)] = []
        for (label, print) in prints where VoicePrints.isGeneric(label) {
            let scores = cents.filter { !taken.contains($0.key) }
                .map { (VoiceMath.dot(print.emb, $0.value), $0.key) }
                .sorted { $0.0 > $1.0 }
            guard let best = scores.first, best.0 >= VoiceThresholds.match else { continue }
            if scores.count > 1, best.0 - scores[1].0 < VoiceThresholds.margin { continue }
            candidates.append((best.0, label, best.1))
        }
        var out: [String: VoiceMatch] = [:]
        var used: Set<String> = []
        for (score, label, name) in candidates.sorted(by: { $0.0 > $1.0 })
        where !used.contains(name) && out[label] == nil {
            out[label] = VoiceMatch(name: name, score: (score * 100).rounded() / 100)
            used.insert(name)
        }
        return out
    }

    /// Запоминает отпечатки названных спикеров встречи (вклад встречи заменяется целиком).
    func remember(meeting: String, prints: [String: VoicePrint]) {
        var store = load()
        for name in Array(store.voices.keys) {
            store.voices[name]?.removeValue(forKey: meeting)
            if store.voices[name]?.isEmpty == true { store.voices.removeValue(forKey: name) }
        }
        let now = Date().timeIntervalSince1970
        for (label, print) in prints where !VoicePrints.isGeneric(label) {
            store.voices[label, default: [:]][meeting] = Entry(
                emb: print.emb.map { ($0 * 100_000).rounded() / 100_000 }, sec: print.sec, ts: now)
        }
        save(store)
    }
}
