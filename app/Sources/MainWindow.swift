// Главное окно: слева встречи и навигация, справа — выбранный экран
// (новая запись, идущая запись, встреча, поиск, голоса, настройки).
import AVFoundation
import SwiftUI

/// Что показано в рабочей области окна.
enum AppRoute: Hashable {
    case new
    case live
    case meeting(URL) // аудиофайл записи
    case search
    case voices
    case settings
}

/// Список записей и их длительности (длительности читаются в фоне и кэшируются).
@MainActor
final class MeetingIndex: ObservableObject {
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var durations: [URL: Double] = [:]
    private var loading: Task<Void, Never>?

    func refresh(from state: AppState) {
        recordings = state.allRecordings
        let missing = recordings.filter { durations[$0] == nil }
        guard !missing.isEmpty else { return }
        loading?.cancel()
        loading = Task {
            for url in missing {
                if Task.isCancelled { return }
                let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                durations[url] = seconds.isFinite ? seconds : 0
            }
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var index = MeetingIndex()
    @State private var savedBeforeRecording: URL?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(index: index)
                .frame(width: 250)
            Rectangle().fill(Design.hairline).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.canvas)
        }
        .frame(minWidth: 940, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowAccessor { window in
            state.mainWindow = window
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            // Окно прежнего интерфейса было маленьким: один раз раскрываем до рабочего размера.
            if !UserDefaults.standard.bool(forKey: "mainWindowResized") {
                UserDefaults.standard.set(true, forKey: "mainWindowResized")
                let size = NSSize(width: 1180, height: 760)
                if window.frame.width < size.width, let screen = window.screen?.visibleFrame {
                    let fitted = NSSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
                    window.setFrame(NSRect(x: screen.midX - fitted.width / 2, y: screen.midY - fitted.height / 2,
                                           width: fitted.width, height: fitted.height), display: true)
                }
            }
        })
        .onAppear {
            WindowBridge.shared.open = { openWindow(id: "main") }
            index.refresh(from: state)
            if state.isRecording { state.route = .live }
        }
        .onChange(of: state.isRecording) { _, recording in
            if recording {
                savedBeforeRecording = state.lastSaved
                state.route = .live
            }
        }
        .onChange(of: state.isSaving) { _, saving in
            guard !saving, !state.isRecording else { return }
            index.refresh(from: state)
            guard state.route == .live else { return }
            // Запись сохранена — открываем её; не удалось — возвращаемся к новой записи.
            if let saved = state.lastSaved, saved != savedBeforeRecording {
                state.route = .meeting(saved)
            } else {
                state.route = .new
            }
        }
        .onChange(of: state.transcribeProgress.count) { _, _ in index.refresh(from: state) }
        .onChange(of: state.outputDir) { _, _ in index.refresh(from: state) }
        .sheet(isPresented: $state.sourceSheetVisible) {
            SourcePickerSheet().environmentObject(state)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.route {
        case .new:
            NewRecordingView()
        case .live:
            LiveRecordingView()
        case .meeting(let audio):
            MeetingView(audio: audio, duration: index.durations[audio])
                .id(audio)
        case .search:
            ArchiveSearchView().padding(.top, 22)
        case .voices:
            page { VoicesView(embedded: true) }
        case .settings:
            page { SettingsView() }
        }
    }

    /// Страница с узкой колонкой по центру (настройки, голоса).
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 44)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Боковая панель

private struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var index: MeetingIndex

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                NavRow(title: "Новая запись", icon: "plus", selected: state.route == .new, bordered: true) {
                    state.route = state.isRecording ? .live : .new
                }
                .padding(.bottom, 4)
                if Hardware.supportsChat {
                    NavRow(title: "Поиск по встречам", icon: "magnifyingglass", selected: state.route == .search) {
                        state.route = .search
                    }
                }
                NavRow(title: "Голоса", icon: "person.wave.2", selected: state.route == .voices) {
                    state.route = .voices
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 40) // место под кнопки окна

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if state.isRecording || state.isSaving {
                        groupTitle(state.isSaving ? "Сохраняется" : "Идёт запись")
                        LiveRow()
                    }
                    ForEach(groups, id: \.title) { group in
                        groupTitle(group.title)
                        ForEach(group.items, id: \.self) { url in
                            MeetingRow(url: url, duration: index.durations[url])
                        }
                    }
                    if index.recordings.isEmpty, !state.isRecording {
                        Text("Записей пока нет. Первая появится здесь после остановки записи.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Design.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                if let line = calendarLine {
                    Label(line, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                HStack(spacing: 4) {
                    NavRow(title: "Настройки", icon: "gearshape", selected: state.route == .settings) {
                        state.route = .settings
                    }
                    if let update = state.availableUpdate {
                        Button {
                            state.openLatestRelease()
                        } label: {
                            Text("обновить")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Design.accent.opacity(0.15)))
                                .foregroundStyle(Design.accent)
                        }
                        .buttonStyle(.plain)
                        .pointingCursor()
                        .help("Доступна версия \(update.version) — открыть страницу релиза")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Design.sidebar)
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 3)
    }

    private var calendarLine: String? {
        guard state.calendarConnected else { return nil }
        if let current = state.currentMeeting { return "идёт · \(current.title)" }
        if let next = state.nextMeeting {
            return "\(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)"
        }
        return nil
    }

    private struct Group {
        let title: String
        var items: [URL]
    }

    /// Записи по дням: сегодня, вчера, на этой неделе, дальше по месяцам.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        var out: [Group] = []
        for url in index.recordings.sorted(by: { MeetingName.date($0) > MeetingName.date($1) }) {
            let date = MeetingName.date(url)
            let title: String
            if calendar.isDateInToday(date) {
                title = "Сегодня"
            } else if calendar.isDateInYesterday(date) {
                title = "Вчера"
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
                title = "На этой неделе"
            } else {
                title = monthFormatter.string(from: date).capitalized
            }
            if out.last?.title == title {
                out[out.count - 1].items.append(url)
            } else {
                out.append(Group(title: title, items: [url]))
            }
        }
        return out
    }
}

private struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var bordered = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(bordered || selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Design.selected : (hovering ? Design.hover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(bordered ? Color.primary.opacity(0.18) : .clear, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LiveRow: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.route = .live
        } label: {
            HStack(spacing: 8) {
                if state.isSaving {
                    ProgressView().controlSize(.mini).frame(width: 8)
                } else {
                    Circle().fill(state.isPaused ? Color.secondary : Design.destructive).frame(width: 8, height: 8)
                }
                Text(state.currentMeeting?.title ?? "Новая встреча")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(state.elapsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(state.route == .live ? Design.selected : (hovering ? Design.hover : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MeetingRow: View {
    @EnvironmentObject var state: AppState
    let url: URL
    let duration: Double?
    @State private var hovering = false

    var body: some View {
        let selected = state.route == .meeting(url)
        Button {
            state.route = .meeting(url)
        } label: {
            HStack(spacing: 6) {
                Text(MeetingName.parse(url).title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if state.transcribeProgress[url] != nil || state.summarizing.contains(url) {
                    ProgressView().controlSize(.mini)
                } else if !state.hasTranscript(url) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Нет расшифровки")
                } else if let duration, duration > 0 {
                    Text(MeetingName.duration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Design.selected : (hovering ? Design.hover : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.deletingPathExtension().lastPathComponent)
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
