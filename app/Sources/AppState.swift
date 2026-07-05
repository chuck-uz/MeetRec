import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Какого именно права не хватает для записи.
enum PermissionIssue {
    case screenCapture
    case microphone
}

extension Notification.Name {
    static let meetrecStartRecording = Notification.Name("ru.dinya.meetrec.startRecording")
}

@MainActor
final class AppState: ObservableObject {
    static private(set) weak var shared: AppState?
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastSaved: URL?
    @Published var errorMessage: String?
    @Published var permissionIssue: PermissionIssue?
    @Published var outputDir: URL {
        didSet { UserDefaults.standard.set(outputDir.path, forKey: "outputDir") }
    }

    @Published var floatOnTop: Bool {
        didSet {
            UserDefaults.standard.set(floatOnTop, forKey: "floatOnTop")
            applyWindowLevel()
        }
    }
    @Published var autoTranscribe: Bool {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published var captureVideo: Bool {
        didSet { UserDefaults.standard.set(captureVideo, forKey: "captureVideo") }
    }
    @Published var diarize: Bool {
        didSet { UserDefaults.standard.set(diarize, forKey: "diarize") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !suppressLoginItemUpdate, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = "Автозапуск: \(error.localizedDescription)"
                suppressLoginItemUpdate = true
                launchAtLogin = oldValue
                suppressLoginItemUpdate = false
            }
        }
    }
    private var suppressLoginItemUpdate = false
    @Published var recordingSizeText: String?
    @Published var transcribeProgress: [URL: String] = [:]
    @Published var modelStatus: String?
    @Published var calendarConnected = false
    @Published var calendarConfigured = false
    @Published var calendarStatus: String?
    @Published var upcomingEvents: [CalendarEvent] = []

    private var calendarTimer: Timer?
    private var notifiedEventIDs: Set<String> = []
    private var meetingHeaders: [URL: String] = [:]

    weak var mainWindow: NSWindow? {
        didSet { applyWindowLevel() }
    }

    private var engine: RecorderEngine?
    private var timer: Timer?
    private var startedAt: Date?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "outputDir"), !saved.isEmpty {
            outputDir = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            outputDir = Self.defaultOutputDir()
        }
        floatOnTop = UserDefaults.standard.bool(forKey: "floatOnTop")
        autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
        captureVideo = UserDefaults.standard.bool(forKey: "captureVideo")
        diarize = UserDefaults.standard.bool(forKey: "diarize")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Self.shared = self
        checkModelUpdate()

        calendarConfigured = GoogleOAuthConfig.load() != nil
        calendarConnected = GoogleAuth.shared.isConnected
        NotificationCenter.default.addObserver(
            forName: .meetrecStartRecording, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording, !self.isSaving else { return }
                self.toggle()
            }
        }
        startCalendarPolling()
    }

    // MARK: - Google Календарь

    func connectCalendar() {
        calendarStatus = "подтвердите доступ в браузере…"
        Task {
            do {
                try await GoogleAuth.shared.connect()
                calendarConnected = true
                calendarStatus = nil
                errorMessage = nil
                await requestNotificationPermission()
                await refreshCalendar()
            } catch {
                calendarStatus = nil
                errorMessage = "Google Календарь: \(error.localizedDescription)"
            }
        }
    }

    func disconnectCalendar() {
        GoogleAuth.shared.disconnect()
        calendarConnected = false
        upcomingEvents = []
    }

    private func startCalendarPolling() {
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.notifyAboutStartingMeetings()
                // Полное обновление списка — раз в 5 минут.
                if Int(Date().timeIntervalSince1970) % 300 < 60 {
                    await self.refreshCalendar()
                }
            }
        }
        Task { await refreshCalendar() }
    }

    func refreshCalendar() async {
        guard calendarConnected else { return }
        do {
            upcomingEvents = try await GoogleCalendarClient.shared.upcomingEvents()
        } catch {
            // Нет сети или токен отозван — не шумим, попробуем в следующий раз.
        }
    }

    var currentMeeting: CalendarEvent? {
        upcomingEvents.first { $0.isNow }
    }

    var nextMeeting: CalendarEvent? {
        upcomingEvents.first { $0.start > Date() }
    }

    // Уведомление в момент начала встречи с кнопкой «Записать».
    private func notifyAboutStartingMeetings() {
        guard calendarConnected, !isRecording else { return }
        let now = Date()
        for event in upcomingEvents
        where event.start <= now && now < event.start.addingTimeInterval(90)
            && !notifiedEventIDs.contains(event.id) {
            notifiedEventIDs.insert(event.id)
            let content = UNMutableNotificationContent()
            content.title = "Встреча началась"
            content.body = event.title
            content.categoryIdentifier = "MEETING_START"
            let request = UNNotificationRequest(
                identifier: "meeting-\(event.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let record = UNNotificationAction(
            identifier: "REC", title: "Записать", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "MEETING_START", actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Раз в сутки сверяет модель распознавания с манифестом в репозитории
    /// и при появлении новой рекомендованной модели скачивает её в фоне.
    func checkModelUpdate(force: Bool = false) {
        let lastCheck = UserDefaults.standard.object(forKey: "lastModelCheck") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(lastCheck) > 86_400 else { return }
        Task {
            do {
                try await Transcriber.shared.updateModelIfNeeded { [weak self] status in
                    Task { @MainActor in self?.modelStatus = status }
                }
                UserDefaults.standard.set(Date(), forKey: "lastModelCheck")
            } catch {
                // Нет сети или манифест недоступен — молча попробуем в другой раз.
            }
            modelStatus = nil
        }
    }

    private func applyWindowLevel() {
        mainWindow?.level = floatOnTop ? .floating : .normal
    }

    static func defaultOutputDir() -> URL {
        let fm = FileManager.default
        // Если установлен Google Drive для рабочего стола — пишем сразу туда.
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("GoogleDrive-") {
                for driveName in ["My Drive", "Мой диск"] {
                    let drive = entry.appendingPathComponent(driveName)
                    if fm.fileExists(atPath: drive.path) {
                        return drive.appendingPathComponent("Записи встреч")
                    }
                }
            }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Записи встреч")
    }

    var elapsedText: String {
        let total = Int(elapsed)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var recentRecordings: [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return items
            .filter { ["m4a", "mov", "mp4"].contains($0.pathExtension.lowercased()) }
            // Видеофайл с аудио-собратом не показываем отдельной строкой.
            .filter { url in
                guard url.pathExtension.lowercased() != "m4a" else { return true }
                let sibling = url.deletingPathExtension().appendingPathExtension("m4a")
                return !fm.fileExists(atPath: sibling.path)
            }
            .sorted { modDate($0) > modDate($1) }
            .prefix(4)
            .map { $0 }
    }

    /// Видеофайл, записанный вместе с этой аудиозаписью.
    func videoURL(for audio: URL) -> URL? {
        let base = audio.deletingPathExtension()
        for ext in ["mp4", "mov"] {
            let candidate = base.appendingPathExtension(ext)
            if candidate != audio, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Управление записью

    func toggle() {
        guard !isSaving else { return }
        if isRecording { stopAndSave() } else { start() }
    }

    /// Проверяет права до запуска захвата: так пользователь получает системный
    /// запрос и понятную подсказку вместо загадочной ошибки от ScreenCaptureKit.
    private func ensurePermissions() async -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            // Показывает системный запрос (один раз) либо просто возвращает false,
            // если пользователь уже отказал — тогда ведём его в настройки.
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                permissionIssue = .screenCapture
                errorMessage = "Нет разрешения на запись экрана и системного звука."
                return false
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                permissionIssue = .microphone
                errorMessage = "Нет доступа к микрофону."
                return false
            }
        default:
            permissionIssue = .microphone
            errorMessage = "Нет доступа к микрофону."
            return false
        }
        return true
    }

    private func handleStartError(_ error: Error) {
        if let scError = error as? SCStreamError {
            switch scError.code {
            case .userDeclined:
                permissionIssue = .screenCapture
                errorMessage = "Нет разрешения на запись экрана и системного звука."
                return
            default:
                break
            }
        }
        // Fallback: ScreenCaptureKit не всегда отдаёт типизированную ошибку.
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("declined")
            || text.localizedCaseInsensitiveContains("отклонил")
            || text.localizedCaseInsensitiveContains("denied")
            || text.localizedCaseInsensitiveContains("TCC") {
            permissionIssue = .screenCapture
            errorMessage = "Нет разрешения на запись звука."
        } else {
            errorMessage = "Не удалось начать запись: \(text)"
        }
    }

    private func start() {
        errorMessage = nil
        permissionIssue = nil
        Task {
            guard await ensurePermissions() else { return }
            do {
                let meeting = currentMeeting
                let title = meeting.map { sanitizeFileName($0.title) }
                let engine = try RecorderEngine(outputDir: outputDir, title: title, captureVideo: captureVideo)
                if let meeting {
                    meetingHeaders[engine.finalURL] = meetingHeader(for: meeting)
                }
                engine.onInterrupted = { [weak self] error in
                    Task { @MainActor in self?.handleInterruption(error) }
                }
                try await engine.start()
                self.engine = engine
                isRecording = true
                startedAt = Date()
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let startedAt = self.startedAt else { return }
                        self.elapsed = Date().timeIntervalSince(startedAt)
                        if self.captureVideo, let temp = self.engine?.tempURL,
                           let bytes = (try? FileManager.default.attributesOfItem(atPath: temp.path))?[.size] as? Int64 {
                            self.recordingSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        }
                    }
                }
            } catch {
                handleStartError(error)
            }
        }
    }

    func stopAndSave() {
        guard let engine, isRecording else { return }
        isRecording = false
        isSaving = true
        timer?.invalidate()
        timer = nil
        Task {
            defer {
                isSaving = false
                recordingSizeText = nil
            }
            do {
                let result = try await engine.stop()
                lastSaved = result.audioURL
                errorMessage = nil
                if autoTranscribe {
                    transcribe(result.audioURL)
                }
            } catch {
                errorMessage = "Ошибка при сохранении: \(error.localizedDescription)"
            }
            self.engine = nil
        }
    }

    // MARK: - Транскрибация

    func hasTranscript(_ audio: URL) -> Bool {
        FileManager.default.fileExists(atPath: Transcriber.transcriptURL(for: audio).path)
    }

    func transcribe(_ audio: URL) {
        guard transcribeProgress[audio] == nil, !hasTranscript(audio) else { return }
        transcribeProgress[audio] = "в очереди…"
        let header = meetingHeaders[audio]
            ?? meetingHeaders[audio.deletingPathExtension().appendingPathExtension("m4a")]
        let diarize = self.diarize
        Task {
            do {
                _ = try await Transcriber.shared.transcribe(audio: audio, header: header, diarize: diarize) { [weak self] status in
                    Task { @MainActor in self?.transcribeProgress[audio] = status }
                }
            } catch {
                errorMessage = "Транскрибация: \(error.localizedDescription)"
            }
            transcribeProgress[audio] = nil
        }
    }

    func openTranscript(_ audio: URL) {
        NSWorkspace.shared.open(Transcriber.transcriptURL(for: audio))
    }

    private func sanitizeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(60))
    }

    private func meetingHeader(for event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        var lines = ["**Встреча:** \(event.title)  ", "**Начало:** \(formatter.string(from: event.start))  "]
        if !event.attendees.isEmpty {
            lines.append("**Участники:** \(event.attendees.joined(separator: ", "))  ")
        }
        return lines.joined(separator: "\n")
    }

    private func handleInterruption(_ error: Error) {
        guard isRecording else { return }
        errorMessage = "Захват прервался, запись сохранена: \(error.localizedDescription)"
        stopAndSave()
    }

    // MARK: - Действия

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять записи встреч"
        panel.directoryURL = outputDir
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDir)
    }

    func openPermissionSettings() {
        let anchor = permissionIssue == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        let pane = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Право на запись экрана применяется только после перезапуска приложения.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func quit() {
        Transcriber.shared.cancelAll()
        if isRecording, let engine {
            isRecording = false
            timer?.invalidate()
            Task {
                _ = try? await engine.stop()
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}
