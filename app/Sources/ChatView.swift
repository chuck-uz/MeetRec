// Модель чата с локальной LLM по транскрипту конкретной встречи (вид — в MeetingView).
import AppKit
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isGenerating = false
    @Published var status: String?
    @Published private(set) var transcriptURL: URL?
    private var transcript = ""
    private var generation: Task<Void, Never>?

    static let templates: [(title: String, prompt: String)] = [
        ("Саммари", "Составь подробное саммари встречи: контекст, ключевые темы и позиции участников, принятые решения. Раскрывай суть, приводи конкретику (системы, цифры, имена)."),
        ("Action items", "Выпиши все action items в формате: исполнитель — задача — срок (если назван). Если исполнитель не назван, напиши «не назначен»."),
        ("Решения", "Перечисли все принятые на встрече решения и договорённости. Только то, что явно прозвучало."),
        ("Письмо-фоллоуап", "Напиши короткое деловое письмо участникам по итогам встречи: что обсудили, что решили, кто что делает."),
    ]

    func open(transcript url: URL) {
        guard url != transcriptURL else { return }
        stop()
        transcriptURL = url
        messages = []
        status = nil
        transcript = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Страховка от сверхдлинных транскриптов (контекст 16К токенов):
        // обрезаем середину, сохраняя начало и конец.
        let limit = 42_000
        if transcript.count > limit {
            let head = transcript.prefix(limit * 2 / 3)
            let tail = transcript.suffix(limit / 3)
            transcript = head + "\n\n[…середина транскрипта опущена из-за длины…]\n\n" + tail
        }
    }

    var meetingTitle: String {
        transcriptURL?.deletingPathExtension().lastPathComponent ?? "Встреча"
    }

    func send(_ text: String? = nil) {
        let question = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating, !transcript.isEmpty else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: question))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isGenerating = true

        var turns: [ChatTurn] = [
            ChatTurn(role: .system, text: """
            Ты — ассистент по рабочим встречам. Ниже транскрипт встречи «\(meetingTitle)» \
            с таймкодами\(transcript.contains("Спикер") ? " и говорящими" : ""). \
            Отвечай на русском, опирайся только на транскрипт; если информации нет — скажи об этом.

            ТРАНСКРИПТ:
            \(transcript)
            """)
        ]
        for message in messages.dropLast() where !message.text.isEmpty {
            turns.append(ChatTurn(role: message.role == .user ? .user : .assistant, text: message.text))
        }

        generation = Task {
            // Не конкурируем за память с Whisper: ждём окончания транскрибаций.
            while let state = AppState.shared, !state.transcribeProgress.isEmpty {
                status = "жду окончания транскрибации…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            do {
                try await LLMRuntime.shared.generate(
                    turns: turns,
                    onToken: { [weak self] token in
                        Task { @MainActor in
                            guard let self, !self.messages.isEmpty else { return }
                            self.status = nil
                            self.messages[self.messages.count - 1].text += token
                        }
                    },
                    onStatus: { [weak self] text in
                        Task { @MainActor in self?.status = text }
                    })
            } catch {
                messages[messages.count - 1].text = "Ошибка: \(error.localizedDescription)"
            }
            status = nil
            isGenerating = false
        }
    }

    func stop() {
        generation?.cancel()
        generation = nil
        isGenerating = false
        status = nil
    }
}
