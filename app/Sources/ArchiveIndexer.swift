// Индексация транскриптов и поиск по всему архиву встреч (локальный RAG).
import Foundation

enum ArchiveIndexer {
    // MARK: - Разбор транскрипта на фрагменты

    private struct Segment {
        let tsStart: Int
        let speaker: String?
        let text: String
    }

    /// Строки вида «**Спикер 1 [00:12]:** текст» или «**[03:12]** текст».
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\*\*(?:(.+?)\s)?\[(\d+):(\d{2})(?::(\d{2}))?\]:?\*\*\s*(.+)$"#)

    private static func parse(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        for line in markdown.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = lineRegex.firstMatch(in: line, range: range) else { continue }
            func group(_ i: Int) -> String? {
                guard m.range(at: i).location != NSNotFound,
                      let r = Range(m.range(at: i), in: line) else { return nil }
                return String(line[r])
            }
            let speaker = group(1)?.trimmingCharacters(in: .whitespaces)
            let g2 = Int(group(2) ?? "0") ?? 0
            let g3 = Int(group(3) ?? "0") ?? 0
            let g4 = group(4).flatMap { Int($0) }
            // [h:mm:ss] если есть четвёртая группа, иначе [mm:ss]
            let seconds = g4 != nil ? g2 * 3600 + g3 * 60 + g4! : g2 * 60 + g3
            let text = (group(5) ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                segments.append(Segment(tsStart: seconds * 1000, speaker: speaker, text: text))
            }
        }
        return segments
    }

    /// Группировка реплик в фрагменты ~1600 символов с перекрытием.
    private static func chunk(
        segments: [Segment], meetingID: String, title: String, date: Date,
        target: Int = 1600, overlap: Int = 250
    ) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        var buffer: [Segment] = []
        var length = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let speakers = Set(buffer.compactMap(\.speaker))
            let text = buffer.map { seg in
                seg.speaker.map { "\($0): \(seg.text)" } ?? seg.text
            }.joined(separator: " ")
            chunks.append(TranscriptChunk(
                meetingID: meetingID, title: title, date: date,
                tsStart: buffer.first!.tsStart,
                speaker: speakers.count == 1 ? speakers.first : nil,
                text: text))
        }

        for seg in segments {
            buffer.append(seg)
            length += seg.text.count
            if length >= target {
                flush()
                var carried: [Segment] = []
                var carriedLen = 0
                while let last = buffer.popLast(), carriedLen < overlap {
                    carried.insert(last, at: 0)
                    carriedLen += last.text.count
                }
                buffer = carried
                length = carriedLen
            }
        }
        flush()
        return chunks
    }

    // MARK: - Индексация

    /// Индексирует один транскрипт, если он новый или изменился.
    static func indexTranscript(
        at url: URL, onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let meetingID = url.deletingPathExtension().lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        guard await ArchiveStore.shared.needsIndex(meetingID: meetingID, mtime: mtime) else { return }

        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let segments = parse(markdown)
        guard !segments.isEmpty else { return }

        let date = (attrs?[.creationDate] as? Date) ?? mtime
        let chunks = chunk(segments: segments, meetingID: meetingID, title: meetingID, date: date)
        let embeddings = try await EmbeddingService.shared.embed(chunks.map(\.text), onStatus: onStatus)
        guard embeddings.count == chunks.count else {
            throw MeetRecError("Число эмбеддингов не совпало с числом фрагментов.")
        }
        try await ArchiveStore.shared.replace(
            meetingID: meetingID, title: meetingID, date: date,
            path: url.path, mtime: mtime,
            chunks: Array(zip(chunks, embeddings)))
    }

    /// Проходит по всем транскриптам в папке записей и индексирует новые/изменённые.
    static func indexAll(
        in folder: URL, onStatus: @escaping @Sendable (String) -> Void
    ) async {
        let fm = FileManager.default
        let transcripts = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" } ?? []
        let ids = Set(transcripts.map { $0.deletingPathExtension().lastPathComponent })
        await ArchiveStore.shared.removeMissing(existingIDs: ids)

        var done = 0
        for url in transcripts {
            do {
                try await indexTranscript(at: url) { _ in }
            } catch {
                // Пропускаем нечитаемый транскрипт, продолжаем остальные.
            }
            done += 1
            onStatus("индексация \(done)/\(transcripts.count)")
        }
        await EmbeddingService.shared.shutdown()
        onStatus("")
    }

    // MARK: - Поиск с ответом (RAG)

    /// Находит релевантные фрагменты по всему архиву.
    static func retrieve(question: String) async throws -> [ArchiveHit] {
        let vec = try await EmbeddingService.shared.embed([question])
        guard let queryVec = vec.first else { return [] }
        return try await ArchiveStore.shared.search(
            queryEmbedding: queryVec, queryText: question, limit: 8)
    }

    /// Формирует промпт из найденных фрагментов для генерации ответа.
    static func buildPrompt(question: String, hits: [ArchiveHit]) -> [ChatTurn] {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "ru_RU")

        let context = hits.enumerated().map { i, hit in
            let ts = timestamp(hit.tsStart)
            let who = hit.speaker.map { "\($0), " } ?? ""
            return "[\(i + 1)] «\(hit.title)», \(formatter.string(from: hit.date)), \(who)\(ts):\n\(hit.text)"
        }.joined(separator: "\n\n")

        let system = """
        Ты — ассистент по архиву рабочих встреч. Отвечай на вопрос, опираясь ТОЛЬКО на \
        приведённые фрагменты встреч. Если ответа в них нет — честно скажи, что не нашёл. \
        Ссылайся на источники в квадратных скобках вида [1], [2] по номеру фрагмента. \
        Отвечай на русском, кратко и по делу.

        ФРАГМЕНТЫ:
        \(context)
        """
        return [
            ChatTurn(role: .system, text: system),
            ChatTurn(role: .user, text: question),
        ]
    }

    private static func timestamp(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
