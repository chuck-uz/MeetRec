// Авто-саммари встречи: по транскрипту локальная LLM формирует итоги
// (кратко / решения / задачи) и кладёт их файлом рядом с записью.
import Foundation

enum Summarizer {
    /// Суффикс файла итогов; по нему же исключаем их из индекса и списков.
    static let suffix = " — итоги"

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
        var text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        guard !text.isEmpty else { throw MeetRecError("Пустой транскрипт.") }

        // Страховка от сверхдлинных транскриптов (контекст модели 16К токенов).
        let limit = 42_000
        if text.count > limit {
            let head = text.prefix(limit * 2 / 3)
            let tail = text.suffix(limit / 3)
            text = head + "\n\n[…середина опущена…]\n\n" + tail
        }

        let title = transcript.deletingPathExtension().lastPathComponent
        let turns = [
            ChatTurn(role: .system, text: """
            Ты — ассистент по рабочим встречам. По транскрипту составь итоги строго в таком \
            markdown-формате и ничего сверх него:

            ## Кратко
            - (3–5 пунктов сути встречи)

            ## Решения
            - (принятые решения и договорённости; если решений нет — «—»)

            ## Задачи
            - исполнитель — задача — срок (если срок назван; если исполнитель не назван — «не назначен»); если задач нет — «—»

            Опирайся только на транскрипт, ничего не придумывай. Отвечай на русском.
            """),
            ChatTurn(role: .user, text: "ТРАНСКРИПТ встречи «\(title)»:\n\(text)"),
        ]

        let body = try await LLMRuntime.shared.complete(turns: turns, onStatus: onStatus)
        let document = "# Итоги: \(title)\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let out = summaryURL(forTranscript: transcript)
        try document.data(using: .utf8)!.write(to: out)
        return out
    }
}
