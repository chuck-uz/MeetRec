import AppKit
import SwiftUI

// Дизайн-токены (палитра «Calm cyan + health green» из ui-ux-pro-max)
enum Design {
    static let primary = Color(red: 0x08 / 255, green: 0x91 / 255, blue: 0xB2 / 255) // #0891B2
    static let secondary = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255) // #22D3EE
    static let accent = Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255) // #059669
    static let destructive = Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255) // #DC2626
    static let destructiveDark = Color(red: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255) // #B91C1C
    static let corner: CGFloat = 12
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 16) {
            header
            recordButton
            if state.isRecording && !state.isSaving {
                pauseControl
            }
            statusLine
            if let message = state.errorMessage {
                errorCard(message)
            }
            Divider()
            folderCard
            videoCard
            transcribeCard
            diarizeCard
            if Hardware.supportsChat {
                summaryCard
            }
            calendarCard
            if !state.recentRecordings.isEmpty {
                recentSection
            }
            Divider()
            footer
        }
        .padding(16)
        .padding(.top, 22) // место под кнопки закрытия окна
        .frame(width: 320)
        .background(WindowAccessor { window in
            state.mainWindow = window
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
        })
        .onAppear {
            WindowBridge.shared.open = { openWindow(id: "main") }
        }
    }

    // MARK: - Секции

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(Design.primary)
            Text("MeetRec")
                .font(.headline)
            Text("v\(UpdateChecker.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if state.availableUpdate != nil {
                Button {
                    state.openLatestRelease()
                } label: {
                    Text("обновить")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Design.accent.opacity(0.15)))
                        .foregroundStyle(Design.accent)
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .help("Доступна версия \(state.availableUpdate?.version ?? "") — открыть страницу релиза")
            }
            Spacer()
            Button {
                state.floatOnTop.toggle()
            } label: {
                Image(systemName: state.floatOnTop ? "pin.fill" : "pin")
                    .foregroundStyle(state.floatOnTop ? Design.primary : .secondary)
            }
            .buttonStyle(.borderless)
            .pointingCursor()
            .help(state.floatOnTop ? "Не закреплять поверх окон" : "Закрепить поверх всех окон")
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(statusIsActive
                        ? Design.destructive.opacity(0.15)
                        : Design.primary.opacity(0.12))
                )
                .foregroundStyle(statusIsActive ? Design.destructive : Design.primary)
        }
    }

    private var statusLabel: String {
        if state.isPaused { return "Пауза" }
        if state.isRecording { return "Запись" }
        if state.isSaving { return "Сохранение" }
        return "Готов"
    }

    private var statusIsActive: Bool {
        state.isRecording && !state.isPaused
    }

    private var pauseControl: some View {
        Button(action: state.pauseResume) {
            Label(state.isPaused ? "Продолжить" : "Пауза",
                  systemImage: state.isPaused ? "play.fill" : "pause.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(state.isPaused ? Design.accent : Design.primary)
        }
        .buttonStyle(.bordered)
        .pointingCursor()
        .help(state.isPaused ? "Продолжить запись" : "Приостановить запись (простой не попадёт в файл)")
    }

    private var recordButton: some View {
        Button(action: state.toggle) {
            ZStack {
                if state.isRecording && !state.isPaused && !reduceMotion {
                    Circle()
                        .stroke(Design.destructive.opacity(0.35), lineWidth: 3)
                        .frame(width: 84, height: 84)
                        .scaleEffect(pulsing ? 1.12 : 0.98)
                        .opacity(pulsing ? 0.2 : 0.7)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
                }
                Circle()
                    .fill(
                        LinearGradient(
                            colors: state.isRecording
                                ? [Design.destructive, Design.destructiveDark]
                                : [Design.secondary, Design.primary],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: (state.isRecording ? Design.destructive : Design.primary).opacity(0.35),
                            radius: 10, y: 4)
                if state.isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if state.isRecording {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 22, height: 22)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.isSaving)
        .pointingCursor()
        .animation(.easeInOut(duration: 0.2), value: state.isRecording)
        .onChange(of: state.isRecording) { _, recording in
            pulsing = recording
        }
        .accessibilityLabel(state.isRecording ? "Остановить запись" : "Начать запись")
    }

    private var statusLine: some View {
        Group {
            if state.isRecording {
                VStack(spacing: 2) {
                    Text(state.elapsedText)
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if let size = state.recordingSizeText {
                        Text("видео · \(size)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else if state.isSaving {
                Text("Сводим дорожки и сохраняем…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let saved = state.lastSaved {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } label: {
                    Label {
                        Text("Сохранено: \(saved.deletingPathExtension().lastPathComponent)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Design.accent)
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .help("Показать файл в Finder")
            } else {
                Text("Нажмите, чтобы записать встречу")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Design.destructive)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Design.destructive)
                    .fixedSize(horizontal: false, vertical: true) // полный текст, без обрезки
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    state.errorMessage = nil
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .help("Скрыть")
            }
            HStack(spacing: 10) {
                Button("Показать логи") { state.openLogs() }
                    .controlSize(.small)
                    .pointingCursor()
                    .help("Открыть файл логов в Finder — можно прислать для разбора")
            }
            if let issue = state.permissionIssue {
                Text(issue == .microphone
                    ? "Разрешите MeetRec доступ в разделе «Микрофон», затем попробуйте снова."
                    : "Включите MeetRec в разделе «Запись экрана и системного звука», затем перезапустите приложение.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Открыть настройки") {
                        state.openPermissionSettings()
                    }
                    .controlSize(.small)
                    .pointingCursor()
                    if issue == .screenCapture {
                        Button("Перезапустить MeetRec") {
                            state.relaunch()
                        }
                        .controlSize(.small)
                        .pointingCursor()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Design.destructive.opacity(0.08))
        )
    }

    private var folderCard: some View {
        HStack(spacing: 8) {
            Image(systemName: folderIsGoogleDrive ? "icloud.fill" : "folder.fill")
                .foregroundStyle(Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(folderIsGoogleDrive ? "Google Диск" : "Папка записей")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.outputDir.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                state.openFolder()
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .pointingCursor()
            .help("Открыть папку в Finder")
            Button("Изменить") {
                state.chooseFolder()
            }
            .controlSize(.small)
            .pointingCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var folderIsGoogleDrive: Bool {
        state.outputDir.path.contains("/CloudStorage/GoogleDrive-")
    }

    private var videoCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.rectangle")
                .foregroundStyle(state.captureVideo ? Design.destructive : Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Видео экрана")
                    .font(.callout.weight(.medium))
                Text(state.captureVideo ? "весь экран, 30 к/с · .mp4 рядом с аудио" : "записывается только звук")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $state.captureVideo)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Design.primary)
                .disabled(state.isRecording || state.isSaving)
                .pointingCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var transcribeCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(Design.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Автотранскрибация")
                    .font(.callout.weight(.medium))
                Text(state.modelStatus ?? "\(Transcriber.modelTitle) · язык распознавания:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(AppState.languageOptions, id: \.code) { option in
                    Button(option.title) { state.transcribeLanguage = option.code }
                }
            } label: {
                Text(languageTitle(state.transcribeLanguage))
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointingCursor()
            .help("Язык распознавания речи")
            Toggle("", isOn: $state.autoTranscribe)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Design.accent)
                .pointingCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func languageTitle(_ code: String) -> String {
        AppState.languageOptions.first { $0.code == code }?.title ?? "Авто"
    }

    private var diarizeCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2")
                .foregroundStyle(state.diarize ? Design.accent : Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Диаризация")
                    .font(.callout.weight(.medium))
                Text(state.diarize ? "транскрипт как диалог: Спикер 1 / Спикер 2…" : "транскрипт без разметки говорящих")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $state.diarize)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Design.accent)
                .pointingCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var summaryCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(state.autoSummary ? Design.accent : Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Авто-итоги встречи")
                    .font(.callout.weight(.medium))
                Text(state.autoSummary ? "кратко · решения · задачи — файл рядом с записью" : "итоги можно собрать вручную у записи")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $state.autoSummary)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Design.accent)
                .pointingCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var calendarCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Google Календарь")
                    .font(.callout.weight(.medium))
                Text(calendarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !state.calendarConfigured {
                EmptyView()
            } else if state.calendarConnected {
                Button {
                    state.disconnectCalendar()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .pointingCursor()
                .help("Отключить календарь")
            } else {
                Button("Подключить") {
                    state.connectCalendar()
                }
                .controlSize(.small)
                .pointingCursor()
                .disabled(state.calendarStatus != nil)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var calendarSubtitle: String {
        if let status = state.calendarStatus {
            return status
        }
        if !state.calendarConfigured {
            return "нет google_oauth.json — см. README"
        }
        if !state.calendarConnected {
            return "автоназвание записей по встречам"
        }
        if let current = state.currentMeeting {
            return "идёт: \(current.title)"
        }
        if let next = state.nextMeeting {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "в \(formatter.string(from: next.start)) — \(next.title)"
        }
        return "ближайших встреч нет"
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Последние записи")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.meetingsTarget = Hardware.supportsChat ? .search : nil
                    openWindow(id: "meetings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Мои встречи", systemImage: "rectangle.stack")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .pointingCursor()
                .help("Все записи, чат с ИИ и поиск по архиву в одном окне")
            }
            ForEach(state.recentRecordings, id: \.self) { url in
                RecentRow(url: url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $state.launchAtLogin) {
                Text("Автозапуск при входе")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .pointingCursor()
            .help("Запускать MeetRec при входе в систему")
            Spacer()
            Button("Завершить") {
                state.quit()
            }
            .controlSize(.small)
            .pointingCursor()
            .help(state.isRecording ? "Запись будет остановлена и сохранена" : "Выйти из MeetRec")
        }
    }
}

private struct RecentRow: View {
    let url: URL
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(Design.primary)
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .help("Открыть запись")

            transcriptControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0))
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var transcriptControl: some View {
        if let video = state.videoURL(for: url) {
            Button {
                NSWorkspace.shared.open(video)
            } label: {
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(Design.primary)
            }
            .buttonStyle(.borderless)
            .pointingCursor()
            .help("Открыть видео")
        }
        if let progress = state.transcribeProgress[url] {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(progress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if state.hasTranscript(url) {
            if Hardware.supportsChat {
                Button {
                    state.meetingsTarget = .recording(url)
                    openWindow(id: "meetings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.caption)
                        .foregroundStyle(Design.primary)
                }
                .buttonStyle(.borderless)
                .pointingCursor()
                .help("Чат с ИИ по этой встрече")
            }
            if Hardware.supportsChat {
                if state.summarizing.contains(url) {
                    ProgressView().controlSize(.mini)
                } else if state.hasSummary(url) {
                    Button {
                        state.openSummary(url)
                    } label: {
                        Image(systemName: "list.bullet.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(Design.accent)
                    }
                    .buttonStyle(.borderless)
                    .pointingCursor()
                    .help("Открыть итоги встречи")
                } else {
                    Button {
                        state.summarize(url)
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .pointingCursor()
                    .help("Собрать итоги встречи")
                }
            }
            Button {
                state.openTranscript(url)
            } label: {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(Design.accent)
            }
            .buttonStyle(.borderless)
            .pointingCursor()
            .help("Открыть транскрипт")
        } else {
            Button {
                state.transcribe(url)
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .pointingCursor()
            .help("Транскрибировать")
        }
    }
}

// Курсор-«рука» на кликабельных элементах
private struct PointingCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func pointingCursor() -> some View {
        modifier(PointingCursor())
    }
}

/// Даёт доступ к NSWindow, в котором находится SwiftUI-иерархия.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
