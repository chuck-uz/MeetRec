// Чат с локальной LLM по транскрипту конкретной встречи.
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
        ("Саммари", "Составь краткое саммари встречи: 3–6 пунктов, только суть."),
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
                messages[messages.count - 1].text = "⚠️ \(error.localizedDescription)"
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

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = ChatViewModel()
    /// Если задан — чат по этому транскрипту; иначе берём state.chatTranscript.
    var transcript: URL? = nil
    /// В окне «Мои встречи» встроено — без фиксированного размера.
    var embedded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            composer
        }
        .frame(minWidth: embedded ? nil : 440, idealWidth: embedded ? nil : 520,
               minHeight: embedded ? nil : 420, idealHeight: embedded ? nil : 620)
        .onAppear { openCurrent() }
        .onChange(of: transcript) { _, _ in openCurrent() }
        .onChange(of: state.chatTranscript) { _, _ in if transcript == nil { openCurrent() } }
    }

    private func openCurrent() {
        if let url = transcript ?? state.chatTranscript {
            model.open(transcript: url)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.meetingTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.status ?? "\(LLMSpec.current.title) · локально, данные не покидают Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isGenerating {
                Button("Стоп") { model.stop() }
                    .controlSize(.small)
                    .pointingCursor()
            }
        }
        .padding(12)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Спросите что-нибудь о встрече или выберите шаблон:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(ChatViewModel.templates, id: \.title) { template in
                Button {
                    model.send(template.prompt)
                } label: {
                    Label(template.title, systemImage: "sparkles")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .pointingCursor()
            }
        }
        .padding(.top, 24)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            ForEach(ChatViewModel.templates.prefix(2), id: \.title) { template in
                Button(template.title) { model.send(template.prompt) }
                    .controlSize(.small)
                    .disabled(model.isGenerating)
                    .pointingCursor()
            }
            TextField("Вопрос по встрече…", text: $model.input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.send() }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.isGenerating ? Color.secondary : Design.primary)
            }
            .buttonStyle(.plain)
            .disabled(model.isGenerating)
            .pointingCursor()
        }
        .padding(12)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .font(.callout)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Design.corner)
                            .fill(message.role == .user
                                ? Design.primary.opacity(0.14)
                                : Color.primary.opacity(0.05))
                    )
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
