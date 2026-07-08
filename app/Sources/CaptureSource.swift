// Источник видеозахвата: весь экран/дисплей или конкретное окно.
// Звук при этом всегда пишется полным (см. RecorderEngine — двойной поток).
import AppKit
import CoreGraphics
import ScreenCaptureKit

enum VideoSource: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)

    /// Весь экран = основной дисплей.
    static var wholeScreen: VideoSource { .display(CGMainDisplayID()) }
}

/// Вариант для меню выбора источника.
struct CaptureSourceOption: Identifiable, Equatable {
    enum Kind { case display, window }
    let id: String
    let title: String
    let subtitle: String?   // имя приложения для окон
    let source: VideoSource
    let kind: Kind
}

enum CaptureSources {
    /// Список источников: «Весь экран», дополнительные мониторы, затем окна.
    /// «Весь экран» присутствует всегда, даже если перечисление недоступно.
    static func list() async -> [CaptureSourceOption] {
        let mainID = CGMainDisplayID()
        var options: [CaptureSourceOption] = [
            .init(id: "whole", title: "Весь экран", subtitle: nil,
                  source: .display(mainID), kind: .display),
        ]
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else {
            return options
        }

        var screenIndex = 2
        for display in content.displays where display.displayID != mainID {
            options.append(.init(
                id: "display-\(display.displayID)",
                title: "Экран \(screenIndex) (\(display.width)×\(display.height))",
                subtitle: nil, source: .display(display.displayID), kind: .display))
            screenIndex += 1
        }

        let own = Bundle.main.bundleIdentifier
        let windows = content.windows
            .filter { window in
                window.isOnScreen && window.windowLayer == 0
                    && (window.title?.isEmpty == false)
                    && window.frame.width >= 120 && window.frame.height >= 120
                    && window.owningApplication?.bundleIdentifier != own
            }
            .sorted { lhs, rhs in
                let a = lhs.owningApplication?.applicationName ?? ""
                let b = rhs.owningApplication?.applicationName ?? ""
                return a == b ? (lhs.title ?? "") < (rhs.title ?? "") : a < b
            }
        for window in windows {
            let app = window.owningApplication?.applicationName ?? "Приложение"
            options.append(.init(
                id: "window-\(window.windowID)",
                title: window.title?.isEmpty == false ? window.title! : app,
                subtitle: app, source: .window(window.windowID), kind: .window))
        }
        return options
    }
}
