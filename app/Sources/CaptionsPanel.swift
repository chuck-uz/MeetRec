// Окно живых субтитров: полупрозрачная панель поверх всех окон и рабочих столов
// (в том числе поверх Zoom на весь экран). Не забирает фокус у приложения встречи
// и исключена из демонстрации экрана (sharingType = .none).
import AppKit
import SwiftUI

@MainActor
final class CaptionsPanel {
    static let shared = CaptionsPanel()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ captioner: LiveCaptioner) {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: CaptionsView(captioner: captioner))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let width: CGFloat = 460, height: CGFloat = 280, margin: CGFloat = 24
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.maxX - width - margin, y: screen.minY + margin, width: width, height: height)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Субтитры"
        panel.isFloatingPanel = true
        panel.level = .statusBar // поверх полноэкранного окна встречи
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0.92
        panel.sharingType = .none // не попадает в демонстрацию экрана и скриншоты
        panel.minSize = NSSize(width: 280, height: 140)
        panel.setFrameUsingName("MeetRecCaptions")
        panel.setFrameAutosaveName("MeetRecCaptions")
        return panel
    }
}

private enum CaptionsMode: String, CaseIterable {
    case both = "оба", translation = "перевод", original = "оригинал"

    var help: String {
        switch self {
        case .both: "Оригинал и перевод"
        case .translation: "Весь разговор на одном языке"
        case .original: "Только расшифровка"
        }
    }
}

private struct CaptionsView: View {
    @ObservedObject var captioner: LiveCaptioner
    @AppStorage("captionsMode") private var mode = CaptionsMode.both.rawValue
    @AppStorage("captionsFontSize") private var fontSize = 15.0

    private var currentMode: CaptionsMode { CaptionsMode(rawValue: mode) ?? .both }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(captioner.entries.suffix(200)) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: captioner.entries) {
                    if let last = captioner.entries.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(.white)
        .textSelection(.enabled)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(captioner.active ? Color.red : Color.gray)
                .frame(width: 7, height: 7)
            Text(captioner.status)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            if let error = captioner.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(CaptionsMode.allCases, id: \.rawValue) { item in
                    Text(item.rawValue).tag(item.rawValue).help(item.help)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("A−") { fontSize = max(11, fontSize - 1) }
                .help("Мельче")
            Button("A+") { fontSize = min(28, fontSize + 1) }
                .help("Крупнее")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private func row(_ entry: CaptionEntry) -> some View {
        let foreign = !entry.target.isEmpty && (entry.translation == nil || entry.shownTranslation != nil)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.speaker)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isMe ? Color.gray : Color(red: 0.56, green: 0.70, blue: 1))
                if !foreign || currentMode != .translation || entry.translation == nil {
                    Text(entry.text)
                        .font(foreign && currentMode == .both ? .system(size: fontSize * 0.85).italic() : nil)
                        .foregroundStyle(entry.isMe || (foreign && currentMode == .both) ? Color.white.opacity(0.7) : .white)
                }
            }
            if foreign, currentMode != .original {
                if let translation = entry.shownTranslation {
                    Text(translation)
                        .fontWeight(.medium)
                } else {
                    Text("перевожу…")
                        .font(.system(size: fontSize * 0.85))
                        .foregroundStyle(.gray)
                }
            }
        }
    }
}
