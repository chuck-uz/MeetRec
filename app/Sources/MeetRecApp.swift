import AppKit
import SwiftUI
import UserNotifications

/// Мост, чтобы AppDelegate мог открыть SwiftUI-окно после его закрытия.
final class WindowBridge {
    static let shared = WindowBridge()
    var open: (() -> Void)?
}

@main
struct MeetRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("MeetRec", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Мои встречи", id: "meetings") {
            MeetingsView()
                .environmentObject(state)
        }
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.isPaused ? "pause.circle.fill"
                    : (state.isRecording ? "record.circle.fill" : "waveform.circle"))
                if state.isRecording {
                    Text(state.elapsedText)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Пункты меню у значка в строке меню.
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(state.isRecording ? "Остановить и сохранить (\(state.elapsedText))" : "Начать запись") {
            state.toggle()
        }
        .disabled(state.isSaving)
        if state.isRecording && !state.isSaving {
            Button(state.isPaused ? "Продолжить запись" : "Пауза") {
                state.pauseResume()
            }
        }
        Button("Открыть MeetRec") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Папка записей") {
            state.openFolder()
        }
        Button("Проверить обновления…") {
            state.checkForUpdates(manual: true)
        }
        Button("Мои встречи…") {
            openWindow(id: "meetings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Завершить MeetRec") {
            state.quit()
        }
    }
}

/// Приложение живёт в строке меню без значка в Dock, поэтому на запуск,
/// повторное открытие и запуск второй копии отвечаем показом главного окна.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let showNotification = Notification.Name("ru.dinya.meetrec.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let bundleID = Bundle.main.bundleIdentifier ?? "ru.dinya.meetrec"
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if copies.count > 1 {
            // Уже есть работающий экземпляр — попросим его показать окно и выйдем.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showMainWindow),
            name: Self.showNotification, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // Cmd+Q / «Завершить» из Dock во время записи: сначала сохранить, потом выйти.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = AppState.shared, state.isRecording || state.isSaving else {
            return .terminateNow
        }
        Task { @MainActor in
            if state.isRecording {
                state.stopAndSave()
            }
            while state.isRecording || state.isSaving {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Гасим дочерний llama-server при выходе, чтобы не оставлять процесс-сироту.
    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await LLMRuntime.shared.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // Клик по уведомлению «Встреча началась» / кнопке «Записать» — начать запись.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.categoryIdentifier == "MEETING_START" {
            NotificationCenter.default.post(name: .meetrecStartRecording, object: nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "MeetRec" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            WindowBridge.shared.open?()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
