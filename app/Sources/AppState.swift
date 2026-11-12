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
    static let meetrecStartRecording = Notification.Name("io.github.chuckuz.meetrec.startRecording")
}

@MainActor
final class AppState: ObservableObject {
    static private(set) weak var shared: AppState?
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isSaving = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastSaved: URL?
    @Published var errorMessage: String? {
        didSet { if let e = errorMessage { Log.error(e) } }
    }
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
    /// Язык распознавания: «auto» или ISO-код (ru/en…).
    @Published var transcribeLanguage: String {
        didSet { UserDefaults.standard.set(transcribeLanguage, forKey: "whisperLanguage") }
    }
    /// Поддерживаемые в UI языки (код → название). auto первым.
    static let languageOptions: [(code: String, title: String)] = [
        ("auto", "Авто"), ("ru", "Русский"), ("en", "English"),
        ("uk", "Українська"), ("kk", "Қазақша"), ("uz", "Oʻzbekcha"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
    ]
    @Published var captureVideo: Bool {
        didSet { UserDefaults.standard.set(captureVideo, forKey: "captureVideo") }
    }
    // Источник видеозахвата (весь экран/дисплей/окно). Не персистим: окна эфемерны.
    @Published var videoSource: VideoSource = .wholeScreen
    @Published var sourceOptions: [CaptureSourceOption] = []
    @Published var sourceSheetVisible = false // диалог выбора источника перед записью
    @Published var diarize: Bool {
        didSet { UserDefaults.standard.set(diarize, forKey: "diarize") }
    }
    @Published var autoSummary: Bool {
        didSet { UserDefaults.standard.set(autoSummary, forKey: "autoSummary") }
    }
    /// Живые субтитры с переводом во время записи (окно поверх экрана).
    @Published var liveCaptions: Bool {
        didSet { UserDefaults.standard.set(liveCaptions, forKey: "liveCaptions") }
    }
    @Published private(set) var captioner: LiveCaptioner?
    /// Узнавать спикеров по голосу между встречами (библиотека голосов).
    @Published var voiceLibrary: Bool {
        didSet { UserDefaults.standard.set(voiceLibrary, forKey: "voiceLibrary") }
    }
    /// Тик для обновления списков говорящих/голосов после переименований.
    @Published private(set) var speakersRevision = 0
    @Published var summarizing: Set<URL> = []
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
    /// Экран в рабочей области главного окна.
    @Published var route: AppRoute = .new
    @Published var availableUpdate: AppRelease?
    @Published var transcribeProgress: [URL: String] = [:]
    @Published var modelStatus: String?
    @Published var calendarConnected = false
    @Published var calendarConfigured = false
    @Published var calendarStatus: String?
    @Published var upcomingEvents: [CalendarEvent] = []

    // Выбор модели ИИ (v1.15)
    @Published var llmModelID: String = LLMCatalog.current.id
    /// Где работает ИИ: "local" или id внешнего провайдера (CloudProvider).
    @Published var llmBackend: String = UserDefaults.standard.string(forKey: LLM.backendKey) ?? "local" {
        didSet {
            UserDefaults.standard.set(llmBackend, forKey: LLM.backendKey)
            // Локальная модель больше не нужна в памяти.
            if llmBackend != "local" { Task { await LLMRuntime.shared.shutdown() } }
        }
    }
    /// Тик: ключ или модель внешнего провайдера изменились.
    @Published var cloudRevision = 0
    @Published var modelDownloads: [String: String] = [:] // id → текст прогресса
    @Published private(set) var modelsRevision = 0        // тик для обновления списка на диске

    private var calendarTimer: Timer?
    private var notifiedEventIDs: Set<String> = []
    private var meetingHeaders: [URL: String] = [:]

    weak var mainWindow: NSWindow? {
        didSet { applyWindowLevel() }
    }

    private var engine: RecorderEngine?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedAccumulated: TimeInterval = 0

    init() {
        if let saved = UserDefaults.standard.string(forKey: "outputDir"), !saved.isEmpty {
            outputDir = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            outputDir = Self.defaultOutputDir()
        }
        floatOnTop = UserDefaults.standard.bool(forKey: "floatOnTop")
        autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
        transcribeLanguage = UserDefaults.standard.string(forKey: "whisperLanguage") ?? Self.defaultLanguage()
        captureVideo = UserDefaults.standard.bool(forKey: "captureVideo")
        diarize = UserDefaults.standard.bool(forKey: "diarize")
        autoSummary = UserDefaults.standard.bool(forKey: "autoSummary")
        liveCaptions = UserDefaults.standard.bool(forKey: "liveCaptions")
        voiceLibrary = UserDefaults.standard.bool(forKey: "voiceLibrary")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Self.shared = self
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--captions-demo"), flag + 1 < args.count {
            let file = URL(fileURLWithPath: args[flag + 1])
            DispatchQueue.main.async { self.startCaptionsDemo(file) }
        }
        // Проверка интерфейса: `MeetRec --preview new|live|meeting|search|voices|settings`
        // открывает нужный экран во второй копии рядом с основной.
        if let flag = args.firstIndex(of: "--preview"), flag + 1 < args.count {
            switch args[flag + 1] {
            case "live": route = .live
            case "search": route = .search
            case "voices": route = .voices
            case "settings": route = .settings
            case "meeting":
                let long = allRecordings.first { audio in
                    hasSummary(audio) && ((try? Data(contentsOf: Transcriber.transcriptURL(for: audio)).count) ?? 0) > 4000
                }
                if let audio = long ?? allRecordings.first(where: { hasTranscript($0) }) {
                    route = .meeting(audio)
                }
            default: route = .new
            }
        }
        if let flag = args.firstIndex(of: "--voice-calibrate"), flag + 2 < args.count {
            let folder = URL(fileURLWithPath: args[flag + 1])
            let report = URL(fileURLWithPath: args[flag + 2])
            let limit = flag + 3 < args.count ? Int(args[flag + 3]) ?? 8 : 8
            Task.detached {
                await VoiceCalibration.run(folder: folder, report: report, limit: limit)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
        Self.killStaleModelServers()
        Log.trimIfNeeded()
        Log.info("MeetRec \(UpdateChecker.currentVersion) запущен · RAM \(Hardware.ramGB) ГБ")
        checkModelUpdate()
        checkForUpdates(manual: false)

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

    // MARK: - Обновления приложения

    /// Проверка обновлений. manual=true — показываем результат в любом случае;
    /// авто-проверка (manual=false) молчит, если новой версии нет, и не чаще раза в сутки.
    func checkForUpdates(manual: Bool) {
        if !manual {
            let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 86_400 else { return }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        }
        Task {
            guard let latest = await UpdateChecker.latestRelease() else {
                if manual { presentUpdateAlert(title: "Не удалось проверить обновления",
                                               text: "Проверьте интернет и попробуйте позже.", release: nil) }
                return
            }
            if UpdateChecker.isNewer(latest.version, than: UpdateChecker.currentVersion) {
                availableUpdate = latest
                if manual {
                    presentUpdateAlert(
                        title: "Доступна версия \(latest.version)",
                        text: "У вас установлена \(UpdateChecker.currentVersion). Открыть страницу релиза, чтобы скачать обновление?",
                        release: latest)
                }
            } else {
                availableUpdate = nil
                if manual {
                    presentUpdateAlert(title: "Установлена последняя версия",
                                       text: "MeetRec \(UpdateChecker.currentVersion) — обновлений нет.", release: nil)
                }
            }
        }
    }

    func openLatestRelease() {
        if let url = availableUpdate?.pageURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentUpdateAlert(title: String, text: String, release: AppRelease?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let release {
            alert.addButton(withTitle: "Открыть страницу релиза")
            alert.addButton(withTitle: "Позже")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

    // MARK: - Модель ИИ (выбор под железо)

    /// Пользователь выбрал модель для чата/итогов. Сервер перезагрузится с новой
    /// моделью при следующем обращении.
    func selectLLM(_ model: LLMModel) {
        LLMCatalog.choose(model)
        llmModelID = model.id
        Task { await LLMRuntime.shared.shutdown() }
    }

    /// Скачать модель заранее (иначе она догрузится сама при первом чате).
    func downloadModel(_ model: LLMModel) {
        guard modelDownloads[model.id] == nil, !LLMCatalog.isDownloaded(model) else { return }
        guard let url = URL(string: model.url) else {
            errorMessage = "Некорректный адрес модели \(model.title)."
            return
        }
        modelDownloads[model.id] = "0%"
        Task {
            do {
                try await Downloader.fetch(from: url, to: LLMCatalog.fileURL(model), label: model.title) { [weak self] status in
                    Task { @MainActor in self?.modelDownloads[model.id] = status }
                }
                modelDownloads[model.id] = nil
                modelsRevision += 1
            } catch {
                modelDownloads[model.id] = nil
                errorMessage = "Не удалось скачать \(model.title): \(error.localizedDescription)"
                Log.error("Загрузка модели \(model.file): \(error.localizedDescription)")
            }
        }
    }

    /// Разовое подтверждение перед загрузкой модели (вызывается из LLMRuntime,
    /// когда файла ещё нет на диске). Модальный диалог поверх любого окна.
    @MainActor
    static func confirmModelDownload(_ model: LLMModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Скачать модель \(model.title)?"
        alert.informativeText = "Для работы ИИ модель нужно один раз загрузить "
            + "(~\(String(format: "%.1f", model.fileGB)) ГБ). Она сохранится на вашем Mac "
            + "и дальше работает локально, без интернета.\n\nМодель полегче можно выбрать "
            + "в разделе «Модель ИИ» (шестерёнка в шапке окна)."
        alert.addButton(withTitle: "Скачать")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Удалить скачанную модель, чтобы освободить диск.
    func deleteModel(_ model: LLMModel) {
        if LLMCatalog.current.id == model.id {
            Task { await LLMRuntime.shared.shutdown() }
        }
        try? FileManager.default.removeItem(at: LLMCatalog.fileURL(model))
        modelsRevision += 1
    }

    // MARK: - Источник видеозахвата

    /// Перечитывает доступные источники (окна динамичны — зовём при открытии диалога).
    func refreshSourceOptions() {
        Task {
            let options = await CaptureSources.list()
            sourceOptions = options
            // Выбранное окно исчезло — откатываемся на весь экран.
            if !options.contains(where: { $0.source == videoSource }) {
                videoSource = .wholeScreen
            }
        }
    }

    private func applyWindowLevel() {
        mainWindow?.level = floatOnTop ? .floating : .normal
    }

    /// По умолчанию — язык системы, если он из известного набора, иначе «auto».
    /// Родной язык для субтитров: язык распознавания, а при «Авто» — язык системы.
    var nativeLanguage: String {
        if transcribeLanguage != "auto" { return transcribeLanguage }
        return Locale.current.language.languageCode?.identifier ?? "ru"
    }

    /// Проверка субтитров без звонка: `MeetRec --captions-demo запись.wav` проигрывает
    /// файл как звук собеседника в реальном темпе и сохраняет субтитры рядом с ним.
    func startCaptionsDemo(_ file: URL) {
        let live = LiveCaptioner(native: nativeLanguage)
        captioner = live
        live.start()
        route = .live
        Log.info("Живые субтитры: демо по файлу \(file.lastPathComponent)")
        Task.detached {
            do {
                let audio = try AVAudioFile(forReading: file)
                let format = audio.processingFormat
                let chunk = AVAudioFrameCount(format.sampleRate / 2)
                while audio.framePosition < audio.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                    try audio.read(into: buffer, frameCount: chunk)
                    let frames = Int(buffer.frameLength)
                    guard frames > 0, let channels = buffer.floatChannelData else { break }
                    let count = Int(format.channelCount)
                    var mono = [Float](repeating: 0, count: frames)
                    for c in 0..<count {
                        for i in 0..<frames { mono[i] += channels[c][i] / Float(count) }
                    }
                    live.callBuffer.push(samples: mono, rate: format.sampleRate)
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                Log.error("Демо субтитров: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(2))
            await live.finish(audioURL: file)
        }
    }

    func showCaptions() {
        if let captioner { CaptionsPanel.shared.show(captioner) }
    }

    static func defaultLanguage() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "auto"
        return languageOptions.contains { $0.code == code } ? code : "auto"
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

    /// Все записи в папке (новые сверху), без видео-дублей аудиофайлов.
    var allRecordings: [URL] {
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
    }

    var recentRecordings: [URL] {
        Array(allRecordings.prefix(4))
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
        if isRecording { stopAndSave() } else { requestStart() }
    }

    /// Старт записи. Если пишем видео — сначала спрашиваем источник (весь экран/
    /// монитор/окно) с живым списком окон; иначе начинаем сразу.
    func requestStart() {
        guard !isRecording, !isSaving, !sourceSheetVisible else { return }
        guard captureVideo else { start(); return }
        refreshSourceOptions()
        // Диалог живёт в главном окне — поднимем его (старт мог прийти из меню-бара).
        WindowBridge.shared.open?()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.sourceSheetVisible = true }
    }

    func confirmSourceSheet() {
        sourceSheetVisible = false
        start()
    }

    func cancelSourceSheet() {
        sourceSheetVisible = false
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
                let engine = try RecorderEngine(outputDir: outputDir, title: title, captureVideo: captureVideo, videoSource: videoSource)
                if let meeting {
                    meetingHeaders[engine.finalURL] = meetingHeader(for: meeting)
                }
                engine.onInterrupted = { [weak self] error in
                    Task { @MainActor in self?.handleInterruption(error) }
                }
                var captioner: LiveCaptioner?
                if liveCaptions {
                    let live = LiveCaptioner(native: nativeLanguage)
                    engine.onAudio = { buffer, isMic in live.push(buffer, mic: isMic) }
                    captioner = live
                }
                try await engine.start()
                if let captioner {
                    await self.captioner?.finish(audioURL: nil)
                    self.captioner = captioner
                    captioner.start()
                    // Субтитры идут в главном окне. Окно поверх экрана — только по кнопке;
                    // если оно осталось открытым с прошлой встречи, переключаем его на новую.
                    if CaptionsPanel.shared.isVisible { CaptionsPanel.shared.show(captioner) }
                }
                Log.info("Запись начата · видео=\(captureVideo)")
                self.engine = engine
                isRecording = true
                isPaused = false
                startedAt = Date()
                pausedAt = nil
                pausedAccumulated = 0
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let startedAt = self.startedAt, !self.isPaused else { return }
                        self.elapsed = Date().timeIntervalSince(startedAt) - self.pausedAccumulated
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

    /// Пауза / продолжение записи. Простой вырезается из итогового файла.
    func pauseResume() {
        guard let engine, isRecording else { return }
        if isPaused {
            // Возобновляем: учитываем прошедшее на паузе время для таймера.
            if let pausedAt { pausedAccumulated += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
            isPaused = false
            engine.resume()
        } else {
            pausedAt = Date()
            isPaused = true
            engine.pause()
        }
    }

    func stopAndSave() {
        guard let engine, isRecording else { return }
        isRecording = false
        isPaused = false
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
                // Субтитры дораспознают хвост до итоговой расшифровки: два whisper сразу не нужны.
                await captioner?.finish(audioURL: result.audioURL)
                CaptionsPanel.shared.hide()
                lastSaved = result.audioURL
                errorMessage = nil
                if autoTranscribe {
                    transcribe(result.audioURL, tracks: result.tracks)
                } else {
                    for url in result.tracks.values { try? FileManager.default.removeItem(at: url) }
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

    func transcribe(_ audio: URL, tracks: [String: URL] = [:]) {
        guard transcribeProgress[audio] == nil, !hasTranscript(audio) else {
            for url in tracks.values { try? FileManager.default.removeItem(at: url) }
            return
        }
        transcribeProgress[audio] = "в очереди…"
        let header = meetingHeaders[audio]
            ?? meetingHeaders[audio.deletingPathExtension().appendingPathExtension("m4a")]
        let diarize = self.diarize
        let voices = self.voiceLibrary && diarize
        Task {
            do {
                Log.info("Транскрибация начата: \(audio.lastPathComponent) · диаризация=\(diarize) · голоса=\(voices) · дорожек \(tracks.count)")
                let transcript = try await Transcriber.shared.transcribe(
                    audio: audio, header: header, diarize: diarize, tracks: tracks, voices: voices
                ) { [weak self] status in
                    Task { @MainActor in self?.transcribeProgress[audio] = status }
                }
                Log.info("Транскрибация готова: \(transcript.lastPathComponent)")
                transcribeProgress[audio] = nil
                // Добавляем встречу в архивный индекс для поиска по всем записям.
                if Hardware.supportsChat {
                    try? await ArchiveIndexer.indexTranscript(at: transcript)
                    await EmbeddingService.shared.shutdown()
                }
                if autoSummary, LLM.available {
                    await runSummary(transcript: transcript, audio: audio)
                }
            } catch {
                errorMessage = "Транскрибация: \(error.localizedDescription)"
                transcribeProgress[audio] = nil
            }
        }
    }

    // MARK: - Говорящие и голоса

    struct SpeakerInfo: Identifiable {
        let label: String
        let sample: String
        let turns: Int
        var recognized: VoiceMatch?
        var id: String { label }
    }

    /// Говорящие из транскрипта-диалога: метка, пример реплики, число реплик.
    func speakers(in audio: URL) async -> [SpeakerInfo] {
        guard let text = try? String(contentsOf: Transcriber.transcriptURL(for: audio), encoding: .utf8) else { return [] }
        var order: [String] = []
        var samples: [String: String] = [:]
        var turns: [String: Int] = [:]
        let pattern = try! NSRegularExpression(pattern: #"^\*\*(.+?) \[[0-9:]+\]:\*\* (.*)$"#, options: .anchorsMatchLines)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let labelRange = Range(match.range(at: 1), in: text),
                  let lineRange = Range(match.range(at: 2), in: text) else { continue }
            let label = String(text[labelRange]), line = String(text[lineRange])
            if turns[label] == nil { order.append(label) }
            turns[label, default: 0] += 1
            if line.count > (samples[label]?.count ?? 0), line.count >= 20 || samples[label] == nil {
                samples[label] = line
            }
        }
        let record = await VoiceLibrary.shared.meeting(audio.deletingPathExtension().lastPathComponent)
        return order.map { label in
            var sample = samples[label] ?? ""
            if sample.count > 160 { sample = String(sample.prefix(160)) + "…" }
            return SpeakerInfo(label: label, sample: sample, turns: turns[label] ?? 0,
                               recognized: record?.speakers[label]?.recognized)
        }
    }

    /// Переименовывает говорящего в транскрипте и итогах, запоминает голос под новым именем.
    func renameSpeaker(in audio: URL, from old: String, to newName: String) {
        let name = String(newName.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        guard !name.isEmpty, name != old else { return }
        let transcript = Transcriber.transcriptURL(for: audio)
        do {
            let text = try String(contentsOf: transcript, encoding: .utf8)
            try text.replacingOccurrences(of: "**\(old) [", with: "**\(name) [")
                .write(to: transcript, atomically: true, encoding: .utf8)
            let summary = Summarizer.summaryURL(forAudio: audio)
            if let summaryText = try? String(contentsOf: summary, encoding: .utf8) {
                let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![\p{L}\p{N}])"#
                let regex = try NSRegularExpression(pattern: pattern)
                let replaced = regex.stringByReplacingMatches(
                    in: summaryText, range: NSRange(summaryText.startIndex..., in: summaryText),
                    withTemplate: NSRegularExpression.escapedTemplate(for: name))
                try replaced.write(to: summary, atomically: true, encoding: .utf8)
            }
        } catch {
            errorMessage = "Не удалось переименовать говорящего: \(error.localizedDescription)"
            return
        }
        Log.info("Говорящий переименован в \(audio.lastPathComponent)")
        let meeting = audio.deletingPathExtension().lastPathComponent
        let learn = voiceLibrary
        Task {
            if var record = await VoiceLibrary.shared.meeting(meeting) {
                var speaker = record.speakers.removeValue(forKey: old) ?? MeetingVoices.Speaker()
                speaker.recognized = nil // имя подтверждено человеком
                if let existing = record.speakers[name], let print = existing.print,
                   print.sec > (speaker.print?.sec ?? 0) {
                    speaker.print = print
                }
                record.speakers[name] = speaker
                await VoiceLibrary.shared.saveMeeting(meeting, record)
                if learn {
                    await VoiceLibrary.shared.remember(meeting: meeting, prints: record.speakers.compactMapValues(\.print))
                }
            }
            if Hardware.supportsChat {
                try? await ArchiveIndexer.indexTranscript(at: transcript)
                await EmbeddingService.shared.shutdown()
            }
            speakersRevision += 1
        }
        speakersRevision += 1
    }

    /// Убирает отметку «узнан по голосу», оставляя имя (пользователь подтвердил).
    func confirmSpeaker(in audio: URL, _ label: String) {
        let meeting = audio.deletingPathExtension().lastPathComponent
        Task {
            guard var record = await VoiceLibrary.shared.meeting(meeting) else { return }
            record.speakers[label]?.recognized = nil
            await VoiceLibrary.shared.saveMeeting(meeting, record)
            speakersRevision += 1
        }
    }

    func forgetVoice(_ name: String) {
        Task {
            await VoiceLibrary.shared.forget(name)
            speakersRevision += 1
        }
    }

    func renameVoice(_ old: String, to new: String) {
        Task {
            await VoiceLibrary.shared.rename(old, to: new)
            speakersRevision += 1
        }
    }

    func forgetAllVoices() {
        Task {
            await VoiceLibrary.shared.forgetAll()
            speakersRevision += 1
        }
    }

    func openTranscript(_ audio: URL) {
        NSWorkspace.shared.open(Transcriber.transcriptURL(for: audio))
    }

    // MARK: - Итоги встречи (авто-саммари)

    func hasSummary(_ audio: URL) -> Bool {
        FileManager.default.fileExists(atPath: Summarizer.summaryURL(forAudio: audio).path)
    }

    func openSummary(_ audio: URL) {
        NSWorkspace.shared.open(Summarizer.summaryURL(forAudio: audio))
    }

    /// Ручной запуск подготовки итогов для конкретной записи.
    func summarize(_ audio: URL) {
        let transcript = Transcriber.transcriptURL(for: audio)
        guard hasTranscript(audio), !summarizing.contains(audio) else { return }
        Task { await runSummary(transcript: transcript, audio: audio) }
    }

    private func runSummary(transcript: URL, audio: URL) async {
        guard !summarizing.contains(audio) else { return }
        summarizing.insert(audio)
        defer { summarizing.remove(audio) }
        do {
            Log.info("Итоги: генерация для \(transcript.lastPathComponent)")
            _ = try await Summarizer.summarize(transcript: transcript)
            Log.info("Итоги: готово для \(transcript.lastPathComponent)")
        } catch {
            errorMessage = "Итоги: \(error.localizedDescription)"
        }
    }

    func openLogs() {
        Log.reveal()
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

    /// Убивает осиротевшие серверы моделей от прошлой (упавшей) сессии —
    /// иначе они держат по ~5 ГБ и приводят к нехватке памяти и таймаутам.
    static func killStaleModelServers() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "MeetRec.app/Contents/MacOS/llama-server"]
        try? process.run()
    }

    func quit() {
        Transcriber.shared.cancelAll()
        Task { await LLMRuntime.shared.shutdown(); await EmbeddingService.shared.shutdown() }
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
