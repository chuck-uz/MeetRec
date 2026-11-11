// Общие элементы оформления: палитра, мелкие контролы, доступ к окну.
import AppKit
import SwiftUI

// Нейтральные поверхности, один фирменный цвет (циан) и красный только для записи.
enum Design {
    static let primary = Color(red: 0x08 / 255, green: 0x91 / 255, blue: 0xB2 / 255) // #0891B2
    static let secondary = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255) // #22D3EE
    static let accent = Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255) // #059669
    static let destructive = Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255) // #DC2626
    static let destructiveDark = Color(red: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255) // #B91C1C
    static let corner: CGFloat = 12

    /// Фон боковой панели — на тон темнее рабочей области.
    static let sidebar = Color.primary.opacity(0.045)
    /// Рабочая область (как страница документа).
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.1)
    static let hover = Color.primary.opacity(0.06)
    static let selected = Color.primary.opacity(0.1)
    /// «Голос» ИИ: итоги и ответы набраны антиквой, интерфейс — гротеском.
    static let voice = Font.system(size: 15, design: .serif)
}

/// Чип-переключатель (опции записи, режимы субтитров, быстрые вопросы).
struct Chip: View {
    let title: String
    var icon: String?
    var isOn = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Design.primary : Color.secondary)
            .background(Capsule().fill(isOn ? Design.primary.opacity(0.12) : (hovering ? Design.hover : .clear)))
            .overlay(Capsule().strokeBorder(isOn ? Design.primary.opacity(0.45) : Color.primary.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingCursor()
    }
}

/// Заполненная кнопка-пилюля (запись / остановка).
struct PillButton: View {
    let title: String
    let icon: String
    var color: Color = .primary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(color == .primary ? Color(nsColor: .textBackgroundColor) : .white)
            .background(Capsule().fill(color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}

/// Сообщение об ошибке с действиями (логи, права, перезапуск).
struct ErrorBanner: View {
    @EnvironmentObject var state: AppState
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Design.destructive)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Design.destructive)
                    .fixedSize(horizontal: false, vertical: true)
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
            if let issue = state.permissionIssue {
                Text(issue == .microphone
                    ? "Разрешите MeetRec доступ в разделе «Микрофон», затем попробуйте снова."
                    : "Включите MeetRec в разделе «Запись экрана и системного звука», затем перезапустите приложение.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Показать логи") { state.openLogs() }
                if let issue = state.permissionIssue {
                    Button("Открыть настройки") { state.openPermissionSettings() }
                    if issue == .screenCapture {
                        Button("Перезапустить MeetRec") { state.relaunch() }
                    }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Design.corner).fill(Design.destructive.opacity(0.08)))
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

/// Название и время встречи из имени файла («Тема — 2026-11-11 15.07»).
enum MeetingName {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.*?)(?: — )?(\d{4}-\d{2}-\d{2} \d{2}\.\d{2})(?: \((\d+)\))?$"#)
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ url: URL) -> (title: String, date: Date?) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let titleRange = Range(match.range(at: 1), in: name),
              let dateRange = Range(match.range(at: 2), in: name) else { return (name, nil) }
        var title = name[titleRange].trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "Встреча" }
        if let copyRange = Range(match.range(at: 3), in: name) { title += " (\(name[copyRange]))" }
        return (title, parser.date(from: String(name[dateRange])))
    }

    static func date(_ url: URL) -> Date {
        parse(url).date
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds)) с" }
        return minutes >= 60 ? "\(minutes / 60) ч \(String(format: "%02d", minutes % 60))" : "\(minutes) мин"
    }
}
