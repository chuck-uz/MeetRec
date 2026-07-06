// Единое окно «Мои встречи»: слева список записей + поиск по архиву,
// справа — чат с ИИ по выбранной записи или окно поиска.
import AppKit
import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.meetingsTarget) {
                if Hardware.supportsChat {
                    Section {
                        Label("Поиск по всем встречам", systemImage: "sparkle.magnifyingglass")
                            .tag(MeetingsTarget.search)
                    }
                }
                Section("Записи") {
                    ForEach(state.allRecordings, id: \.self) { url in
                        MeetingRow(url: url)
                            .tag(MeetingsTarget.recording(url))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 250)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.meetingsTarget {
        case .search:
            ArchiveSearchView()
        case .recording(let audio):
            RecordingDetail(audio: audio)
                .id(audio) // пересоздаём при смене записи
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Design.primary.opacity(0.5))
            Text("Выберите запись слева, чтобы поговорить о ней с ИИ")
                .font(.callout)
                .foregroundStyle(.secondary)
            if Hardware.supportsChat {
                Text("или откройте «Поиск по всем встречам»")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Строка записи в боковом списке.
private struct MeetingRow: View {
    @EnvironmentObject var state: AppState
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.videoURL(for: url) != nil ? "film" : "waveform")
                .foregroundStyle(Design.primary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if state.hasTranscript(url) {
                        badge("text.quote")
                    }
                    if state.hasSummary(url) {
                        badge("list.bullet.rectangle")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ system: String) -> some View {
        Image(systemName: system)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// Правая панель для выбранной записи: чат по ИИ + быстрые действия.
private struct RecordingDetail: View {
    @EnvironmentObject var state: AppState
    let audio: URL

    var body: some View {
        VStack(spacing: 0) {
            actionsBar
            Divider()
            content
        }
    }

    private var actionsBar: some View {
        HStack(spacing: 10) {
            Text(audio.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.open(audio)
            } label: {
                Label("Открыть", systemImage: "play.circle")
            }
            .pointingCursor()
            if let video = state.videoURL(for: audio) {
                Button {
                    NSWorkspace.shared.open(video)
                } label: {
                    Label("Видео", systemImage: "film")
                }
                .pointingCursor()
            }
            if state.hasTranscript(audio) {
                Button {
                    state.openTranscript(audio)
                } label: {
                    Label("Транскрипт", systemImage: "doc.text")
                }
                .pointingCursor()
            }
            if state.hasSummary(audio) {
                Button {
                    state.openSummary(audio)
                } label: {
                    Label("Итоги", systemImage: "list.bullet.rectangle")
                }
                .pointingCursor()
            }
        }
        .controlSize(.small)
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if !state.hasTranscript(audio) {
            noTranscript
        } else if !Hardware.supportsChat {
            needMoreMemory
        } else {
            ChatView(transcript: Transcriber.transcriptURL(for: audio), embedded: true)
        }
    }

    private var noTranscript: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Design.primary.opacity(0.5))
            Text("Для этой записи ещё нет транскрипта")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let progress = state.transcribeProgress[audio] {
                Label(progress, systemImage: "ellipsis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    state.transcribe(audio)
                } label: {
                    Label("Транскрибировать", systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .pointingCursor()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needMoreMemory: some View {
        VStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Чат с ИИ доступен на Mac с 16+ ГБ памяти")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Открыть транскрипт") { state.openTranscript(audio) }
                .pointingCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
