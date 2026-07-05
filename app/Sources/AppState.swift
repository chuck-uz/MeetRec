import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastSaved: URL?
    @Published var errorMessage: String?
    @Published var permissionProblem = false
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
    @Published var transcribeProgress: [URL: String] = [:]

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
            .filter { ["m4a", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { modDate($0) > modDate($1) }
            .prefix(4)
            .map { $0 }
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Управление записью

    func toggle() {
        guard !isSaving else { return }
        if isRecording { stopAndSave() } else { start() }
    }

    private func start() {
        errorMessage = nil
        permissionProblem = false
        Task {
            do {
                let engine = try RecorderEngine(outputDir: outputDir)
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
                    }
                }
            } catch {
                let text = error.localizedDescription
                if text.localizedCaseInsensitiveContains("declined")
                    || text.localizedCaseInsensitiveContains("отклонил")
                    || text.localizedCaseInsensitiveContains("TCC") {
                    permissionProblem = true
                    errorMessage = "Нет разрешения на запись звука."
                } else {
                    errorMessage = "Не удалось начать запись: \(text)"
                }
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
            defer { isSaving = false }
            do {
                lastSaved = try await engine.stop()
                errorMessage = nil
                if autoTranscribe, let saved = lastSaved {
                    transcribe(saved)
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
        Task {
            do {
                _ = try await Transcriber.shared.transcribe(audio: audio) { [weak self] status in
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
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
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
