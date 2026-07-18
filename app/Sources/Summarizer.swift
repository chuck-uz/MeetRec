// Авто-саммари встречи: по транскрипту локальная LLM формирует итоги
// (контекст / обсуждение / решения / задачи / открытые вопросы) и кладёт их
// файлом рядом с записью.
//
// Короткие встречи обобщаются одним запросом. Длинные (не влезают в контекст
// LLM) — по схеме map-reduce: транскрипт режется на куски, каждый обобщается
// отдельно (map), затем выжимки сводятся в единые итоги (reduce). Так покрывается
// вся встреча, а не только начало и конец.
import Foundation

enum Summarizer {
    /// Суффикс файла итогов; по нему же исключаем их из индекса и списков.
    static let suffix = " — итоги"

    /// Транскрипт короче — обобщаем одним запросом (влезает в контекст 32К).
    private static let singlePassLimit = 40_000
    /// Размер куска для map-фазы (оставляем место под промпт и вывод).
    private static let chunkLimit = 28_000

    static func summaryURL(forTranscript transcript: URL) -> URL {
        let base = transcript.deletingPathExtension().lastPathComponent
        return transcript.deletingLastPathComponent()
            .appendingPathComponent(base + suffix + ".md")
    }

    static func summaryURL(forAudio audio: URL) -> URL {
        summaryURL(forTranscript: Transcriber.transcriptURL(for: audio))
    }

    static func isSummary(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix(suffix)
    }

    /// Генерирует итоги по транскрипту и сохраняет их. Возвращает путь к файлу.
    @discardableResult
    static func summarize(
        transcript: URL,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> URL {
        let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        guard !text.isEmpty else { throw MeetRecError("Пустой транскрипт.") }

        let title = transcript.deletingPathExtension().lastPathComponent
        let body: String
        if text.count <= singlePassLimit {
            body = try await singlePass(title: title, transcript: text, onStatus: onStatus)
        } else {
            body = try await mapReduce(title: title, transcript: text, onStatus: onStatus)
        }

        let document = "# Итоги: \(title)\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let out = summaryURL(forTranscript: transcript)
        try document.data(using: .utf8)!.write(to: out)
        return out
    }

    // MARK: - Один запрос (короткие встречи)

    private static func singlePass(
        title: String, transcript: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let turns = [
            ChatTurn(role: .system, text: finalSystemPrompt(reducing: false)),
            ChatTurn(role: .user, text: "ТРАНСКРИПТ встречи «\(title)»:\n\(transcript)"),
        ]
        return try await LLMRuntime.shared.complete(turns: turns, onStatus: onStatus)
    }

    // MARK: - Map-reduce (длинные встречи)

    private static func mapReduce(
        title: String, transcript: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let chunks = chunk(transcript, limit: chunkLimit)

        // MAP: обобщаем каждый кусок отдельно.
        var partials: [String] = []
        for (i, part) in chunks.enumerated() {
            onStatus("итоги: фрагмент \(i + 1)/\(chunks.count)…")
            let summary = try await mapChunk(title: title, chunk: part, index: i + 1, total: chunks.count)
            partials.append("### Фрагмент \(i + 1)\n\(summary)")
        }

        // Если выжимки сами не влезают (очень длинная встреча) — сжимаем по уровням.
        var combined = partials.joined(separator: "\n\n")
        while combined.count > singlePassLimit {
            onStatus("итоги: промежуточное сведение…")
            let groups = chunk(combined, limit: chunkLimit)
            var reduced: [String] = []
            for (i, group) in groups.enumerated() {
                reduced.append(try await mapChunk(title: title, chunk: group, index: i + 1, total: groups.count))
            }
            combined = reduced.joined(separator: "\n\n")
        }

        // REDUCE: сводим выжимки в единые итоги.
        onStatus("итоги: сведение…")
        let turns = [
            ChatTurn(role: .system, text: finalSystemPrompt(reducing: true)),
            ChatTurn(role: .user, text: "ВЫЖИМКИ ФРАГМЕНТОВ встречи «\(title)» (по порядку):\n\n\(combined)"),
        ]
        return try await LLMRuntime.shared.complete(turns: turns, onStatus: { _ in })
    }

    /// Обобщает один кусок: только факты этого фрагмента, компактно.
    private static func mapChunk(
        title: String, chunk: String, index: Int, total: Int
    ) async throws -> String {
        let turns = [
            ChatTurn(role: .system, text: """
            Ты обрабатываешь ФРАГМЕНТ \(index) из \(total) одной рабочей встречи «\(title)». \
            Кратко выпиши ТОЛЬКО по этому фрагменту, с конкретикой (имена, цифры, названия систем):
            - обсуждаемые темы и позиции сторон;
            - принятые решения;
            - задачи в формате: исполнитель — задача — срок (если назван);
            - открытые вопросы.
            Только факты из фрагмента, ничего не выдумывай. Без вступлений и заключений. \
            Пиши по-русски, компактно.
            """),
            ChatTurn(role: .user, text: "ФРАГМЕНТ ТРАНСКРИПТА:\n\(chunk)"),
        ]
        return try await LLMRuntime.shared.complete(turns: turns, onStatus: { _ in })
    }

    // MARK: - Общий формат итогов

    private static let formatInstructions = """
    Формат — строго эти разделы markdown:

    ## Контекст
    2–4 предложения: о чём встреча и какую проблему решают.

    ## Ключевое обсуждение
    Основные темы и позиции участников (кто что предлагал и возражал), ключевые \
    аргументы. Несколько содержательных пунктов.

    ## Решения
    Что конкретно решили и о чём договорились. Если решений нет — «—».

    ## Задачи
    Action items в формате: **исполнитель** — задача — срок (если назван). \
    Если исполнитель не назван — «не назначен». Если задач нет — «—».

    ## Открытые вопросы
    Что осталось нерешённым или отложено. Если ничего — «—».
    """

    private static func finalSystemPrompt(reducing: Bool) -> String {
        if reducing {
            return """
            Ты — опытный ассистент по рабочим встречам. Ниже — последовательные выжимки \
            фрагментов ОДНОЙ длинной встречи. Составь по ним ЕДИНЫЕ подробные итоги: объедини \
            повторяющееся, сохрани ВСЕ решения и задачи, приводи конкретику (имена, цифры, системы).

            \(formatInstructions)

            Опирайся только на выжимки, ничего не выдумывай. Пиши на русском, по-деловому.
            """
        }
        return """
        Ты — опытный ассистент по рабочим встречам. Составь ПОДРОБНЫЕ, содержательные \
        итоги встречи по транскрипту. Раскрывай контекст, позиции сторон и аргументы, \
        приводи конкретику (названия систем, цифры, имена участников). Расшифровывай \
        очевидный жаргон, если он искажён в тексте. Не будь кратким в ущерб сути.

        \(formatInstructions)

        Опирайся только на транскрипт, ничего не выдумывай. Пиши на русском, по-деловому.
        """
    }

    // MARK: - Нарезка на куски (по границам строк)

    /// Режет текст на куски не длиннее `limit`, по возможности по границам строк,
    /// чтобы не рвать предложения и сохранить таймкоды.
    static func chunk(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            // Одна строка длиннее лимита (редко) — режем её жёстко.
            if line.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                var rest = Substring(line)
                while rest.count > limit {
                    chunks.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
                current = String(rest)
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count > limit {
                chunks.append(current)
                current = line
            } else {
                current += "\n" + line
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
