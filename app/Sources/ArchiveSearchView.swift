// Поиск по всему архиву встреч: вопрос → релевантные фрагменты → ответ ИИ.
import AppKit
import SwiftUI

@MainActor
final class ArchiveSearchModel: ObservableObject {
    @Published var query = ""
    @Published var answer = ""
    @Published var hits: [ArchiveHit] = []
    @Published var status: String?
    @Published var isBusy = false
    @Published var indexingStatus: String?

    private var task: Task<Void, Never>?

    func indexInBackground(folder: URL) {
        Task {
            await ArchiveIndexer.indexAll(in: folder) { [weak self] status in
                Task { @MainActor in
                    self?.indexingStatus = status.isEmpty ? nil : status
                }
            }
        }
    }

    func ask() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        isBusy = true
        answer = ""
        hits = []
        status = "ищу по архиву…"

        task = Task {
            do {
                // Не конкурируем за память с активной транскрибацией.
                while let state = AppState.shared, !state.transcribeProgress.isEmpty {
                    status = "жду окончания транскрибации…"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                let found = try await ArchiveIndexer.retrieve(question: question)
                await EmbeddingService.shared.shutdown() // освобождаем память под LLM
                hits = found
                guard !found.isEmpty else {
                    answer = "В архиве не нашлось релевантных фрагментов по этому вопросу."
                    status = nil
                    isBusy = false
                    return
                }
                status = "формулирую ответ…"
                let turns = ArchiveIndexer.buildPrompt(question: question, hits: found)
                try await LLMRuntime.shared.generate(
                    turns: turns,
                    onToken: { [weak self] token in
                        Task { @MainActor in
                            self?.status = nil
                            self?.answer += token
                        }
                    },
                    onStatus: { [weak self] text in
                        Task { @MainActor in self?.status = text }
                    })
            } catch {
                answer = "⚠️ \(error.localizedDescription)"
            }
            status = nil
            isBusy = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isBusy = false
        status = nil
    }
}

struct ArchiveSearchView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = ArchiveSearchModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.answer.isEmpty && model.hits.isEmpty {
                        emptyState
                    }
                    if !model.answer.isEmpty {
                        answerBlock
                    }
                    if !model.hits.isEmpty {
                        sourcesBlock
                    }
                }
                .padding(14)
            }
            Divider()
            composer
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 640)
        .onAppear { model.indexInBackground(folder: state.outputDir) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Поиск по всем встречам")
                    .font(.headline)
                Text(model.status ?? model.indexingStatus
                    ?? "Спросите что угодно — ответ по всему архиву, локально")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isBusy {
                Button("Стоп") { model.stop() }
                    .controlSize(.small)
                    .pointingCursor()
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Примеры вопросов:")
                .font(.callout).foregroundStyle(.secondary)
            ForEach([
                "Что решили по деплою бэкенда в прошлом месяце?",
                "Какие сроки мы называли по мобильному релизу?",
                "О чём договорились с юристами?",
            ], id: \.self) { example in
                Button {
                    model.query = example
                    model.ask()
                } label: {
                    Label(example, systemImage: "text.magnifyingglass")
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .pointingCursor()
            }
        }
        .padding(.top, 20)
    }

    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ответ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(model.answer.isEmpty ? "…" : model.answer)
                .textSelection(.enabled)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Design.corner)
                        .fill(Design.primary.opacity(0.08)))
        }
    }

    private var sourcesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Источники")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: hit.transcriptPath))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("[\(index + 1)]").font(.caption.weight(.bold))
                                .foregroundStyle(Design.primary)
                            Text(hit.title).font(.caption.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(hit.date, format: .dateTime.day().month().year())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(hit.text)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .help("Открыть транскрипт")
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Вопрос по всем встречам…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.ask() }
            Button {
                model.ask()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.isBusy ? Color.secondary : Design.primary)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .pointingCursor()
        }
        .padding(12)
    }
}
