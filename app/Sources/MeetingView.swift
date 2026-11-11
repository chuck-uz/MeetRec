// Экран встречи: итоги и чат с ИИ в центре, расшифровка с плеером и говорящие справа.
import AVFoundation
import SwiftUI

struct TranscriptLine: Identifiable {
    let id: Int
    let speaker: String?
    let seconds: Double
    let text: String

    /// Разбирает транскрипт MeetRec: «**Имя [мм:сс]:** текст» или «**[мм:сс]** текст».
    static func parse(_ markdown: String) -> [TranscriptLine] {
        let pattern = try! NSRegularExpression(
            pattern: #"^\*\*(?:(.+?) )?\[([0-9:]+)\]:?\*\* ?(.*)$"#, options: .anchorsMatchLines)
        var out: [TranscriptLine] = []
        for match in pattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let timeRange = Range(match.range(at: 2), in: markdown),
                  let textRange = Range(match.range(at: 3), in: markdown) else { continue }
            let speaker = Range(match.range(at: 1), in: markdown).map { String(markdown[$0]) }
            let seconds = markdown[timeRange].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            out.append(TranscriptLine(id: out.count, speaker: speaker, seconds: seconds, text: String(markdown[textRange])))
        }
        return out
    }
}

/// Проигрыватель записи: старт с таймкода реплики, пауза, перемотка.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVPlayer?
    private var observer: Any?

    func load(_ url: URL) {
        unload()
        let player = AVPlayer(url: url)
        self.player = player
        Task {
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            duration = seconds.isFinite ? seconds : 0
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.time = time.seconds
                self.isPlaying = player.rate != 0
            }
        }
    }

    func unload() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        time = 0
    }

    func toggle() {
        guard let player else { return }
        if player.rate != 0 { player.pause() } else { player.play() }
        isPlaying = player.rate != 0
    }

    func seek(to seconds: Double, play: Bool = true) {
        guard let player else { return }
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play {
            player.play()
            isPlaying = true
        }
    }
}

struct MeetingView: View {
    @EnvironmentObject var state: AppState
    let audio: URL
    let duration: Double?

    @StateObject private var chat = ChatViewModel()
    @StateObject private var player = PlayerModel()
    @AppStorage("transcriptPaneVisible") private var paneVisible = true
    @State private var tab: Tab = .summary
    @State private var paneTab: PaneTab = .transcript
    @State private var lines: [TranscriptLine] = []
    @State private var summary: String?
    @State private var captions: String?
    @State private var speakers: [AppState.SpeakerInfo] = []

    private enum Tab: String { case summary = "Итоги и чат", transcript = "Расшифровка", captions = "Субтитры" }
    private enum PaneTab: String, CaseIterable { case transcript = "Расшифровка", speakers = "Говорящие" }

    private var hasTranscript: Bool { state.hasTranscript(audio) }
    private var showsPane: Bool { paneVisible && hasTranscript && tab != .transcript }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Design.hairline).frame(height: 1)
                if !hasTranscript {
                    noTranscript
                } else {
                    switch tab {
                    case .summary: summaryAndChat
                    case .transcript: transcriptList(wide: true)
                    case .captions: captionsPage
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsPane {
                Rectangle().fill(Design.hairline).frame(width: 1)
                pane.frame(width: 320)
            }
        }
        .task(id: reloadKey) { await reload() }
        .onAppear { player.load(audio) }
        .onDisappear {
            player.unload()
            chat.stop()
        }
    }

    private var reloadKey: String {
        "\(audio.path)#\(state.speakersRevision)#\(state.transcribeProgress[audio] ?? "")#\(state.summarizing.contains(audio))"
    }

    private func reload() async {
        let transcriptURL = Transcriber.transcriptURL(for: audio)
        let text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        lines = TranscriptLine.parse(text)
        summary = try? String(contentsOf: Summarizer.summaryURL(forAudio: audio), encoding: .utf8)
        captions = try? String(contentsOf: LiveCaptioner.captionsURL(forAudio: audio), encoding: .utf8)
        speakers = await state.speakers(in: audio)
        if !text.isEmpty { chat.open(transcript: transcriptURL) }
        if tab == .captions, captions == nil { tab = .summary }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingName.parse(audio).title)
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Открыть аудио") { NSWorkspace.shared.open(audio) }
                    if let video = state.videoURL(for: audio) {
                        Button("Открыть видео") { NSWorkspace.shared.open(video) }
                    }
                    if hasTranscript {
                        Button("Открыть файл расшифровки") { state.openTranscript(audio) }
                    }
                    if state.hasSummary(audio) {
                        Button("Открыть файл итогов") { state.openSummary(audio) }
                    }
                    Divider()
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Файлы записи")
                if hasTranscript {
                    Button {
                        paneVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(showsPane ? Design.primary : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(tab == .transcript)
                    .help(paneVisible ? "Скрыть расшифровку справа" : "Показать расшифровку справа")
                }
            }
            if hasTranscript {
                HStack(spacing: 14) {
                    tabButton(.summary)
                    tabButton(.transcript)
                    if captions != nil { tabButton(.captions) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, hasTranscript ? 0 : 12)
    }

    private var subtitle: String {
        var parts: [String] = []
        let date = MeetingName.date(audio)
        if date != .distantPast {
            parts.append(date.formatted(.dateTime.day().month(.wide).hour().minute()))
        }
        if let duration, duration > 0 { parts.append(MeetingName.duration(duration)) }
        if !speakers.isEmpty { parts.append(speakers.map(\.label).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func tabButton(_ value: Tab) -> some View {
        Button {
            tab = value
        } label: {
            Text(value.rawValue)
                .font(.system(size: 12.5))
                .foregroundStyle(tab == value ? Color.primary : Color.secondary)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(tab == value ? Color.primary : .clear).frame(height: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Нет расшифровки

    private var noTranscript: some View {
        VStack(spacing: 12) {
            Text("У этой записи ещё нет расшифровки")
                .font(.system(size: 17, design: .serif))
            if let progress = state.transcribeProgress[audio] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                }
            } else {
                PillButton(title: "Расшифровать", icon: "text.quote") { state.transcribe(audio) }
            }
            playerBar.frame(maxWidth: 420).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Итоги и чат

    private var summaryAndChat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryBlock
                        ForEach(chat.messages) { message in
                            messageView(message).id(message.id)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if let summary {
            MarkdownLite(text: summary, skipTitle: true)
        } else if state.summarizing.contains(audio) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Собираю итоги встречи…").foregroundStyle(.secondary)
            }
        } else if Hardware.supportsChat {
            VStack(alignment: .leading, spacing: 8) {
                Text("Итогов пока нет")
                    .font(.system(size: 17, design: .serif))
                Text("Локальная модель составит «Кратко / Решения / Задачи» по расшифровке.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Chip(title: "Собрать итоги", icon: "list.bullet.rectangle") { state.summarize(audio) }
            }
        } else {
            Text("Итоги и чат с ИИ доступны на Mac с 16+ ГБ памяти. Расшифровка — на вкладке рядом.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Design.hover))
            }
        } else if message.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(chat.status ?? "думаю…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            MarkdownLite(text: message.text)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Hardware.supportsChat, !chat.isGenerating {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ChatViewModel.templates, id: \.title) { template in
                            Chip(title: template.title) { chat.send(template.prompt) }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(Hardware.supportsChat ? "Спросите о встрече" : "Чат доступен на Mac с 16+ ГБ памяти",
                          text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .disabled(!Hardware.supportsChat)
                    .onSubmit { chat.send() }
                if chat.isGenerating {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .help("Остановить ответ")
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(chat.input.isEmpty ? Color.secondary.opacity(0.5) : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.input.isEmpty || !Hardware.supportsChat)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            Text("\(LLMSpec.current.title) · локально, данные не покидают Mac")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Расшифровка, субтитры, говорящие

    private func transcriptList(wide: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: wide ? 12 : 10) {
                    if lines.isEmpty {
                        Text("В записи не нашлось речи — расшифровка пустая.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    ForEach(lines) { line in
                        lineView(line, wide: wide)
                    }
                }
                .frame(maxWidth: wide ? 720 : .infinity, alignment: .leading)
                .padding(.horizontal, wide ? 24 : 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(Design.hairline).frame(height: 1)
            playerBar
                .frame(maxWidth: wide ? 720 : .infinity)
                .padding(.horizontal, wide ? 24 : 12)
                .padding(.vertical, 8)
        }
    }

    private func isCurrent(_ line: TranscriptLine) -> Bool {
        guard player.isPlaying || player.time > 0 else { return false }
        let next = line.id + 1 < lines.count ? lines[line.id + 1].seconds : .infinity
        return player.time >= line.seconds && player.time < next
    }

    private func lineView(_ line: TranscriptLine, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let speaker = line.speaker {
                    Text(speaker).font(.system(size: 12, weight: .medium))
                    if let match = speakers.first(where: { $0.label == speaker })?.recognized {
                        Text("по голосу \(String(format: "%.2f", match.score))")
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Design.primary.opacity(0.12)))
                            .foregroundStyle(Design.primary)
                    }
                }
                Button {
                    player.seek(to: line.seconds)
                } label: {
                    Text(LiveCaptioner.clock(line.seconds))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .help("Слушать с этого места")
            }
            Text(line.text)
                .font(.system(size: wide ? 14 : 12.5))
                .foregroundStyle(wide ? Color.primary : Color.primary.opacity(0.8))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent(line) ? Design.primary.opacity(0.1) : .clear))
    }

    private var playerBar: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Пауза" : "Слушать запись")
            Slider(
                value: Binding(get: { player.time }, set: { player.seek(to: $0, play: player.isPlaying) }),
                in: 0...max(player.duration, 1))
                .controlSize(.mini)
            Text(LiveCaptioner.clock(player.time))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var captionsPage: some View {
        ScrollView {
            MarkdownLite(text: captions ?? "", skipTitle: true, serif: false)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
    }

    private var pane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(PaneTab.allCases, id: \.self) { value in
                    Button {
                        paneTab = value
                    } label: {
                        Text(value.rawValue)
                            .font(.system(size: 12.5))
                            .foregroundStyle(paneTab == value ? Color.primary : Color.secondary)
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(paneTab == value ? Color.primary : .clear).frame(height: 1.5)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if speakers.contains(where: { $0.recognized != nil }) {
                    Image(systemName: "waveform.badge.checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.primary)
                        .help("Есть имена, данные по голосу — проверьте их на вкладке «Говорящие»")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            Rectangle().fill(Design.hairline).frame(height: 1)
            switch paneTab {
            case .transcript:
                transcriptList(wide: false)
            case .speakers:
                ScrollView {
                    SpeakersList(audio: audio, speakers: speakers)
                        .padding(14)
                }
            }
        }
    }
}

/// Упрощённый рендер Markdown итогов, ответов ИИ и субтитров:
/// заголовки, списки, цитаты, абзацы; внутри строки — жирный и курсив.
struct MarkdownLite: View {
    let text: String
    var skipTitle = false
    var serif = true

    private enum Block {
        case heading(String)
        case bullet(String)
        case quote(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                if !skipTitle { out.append(.heading(String(line.dropFirst(2)))) }
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                out.append(.heading(line.drop { $0 == "#" || $0 == " " }.description))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                out.append(.quote(String(line.dropFirst(2))))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    private var bodyFont: Font { serif ? Design.voice : .system(size: 13.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let title):
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                case .bullet(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(inline(item)).font(bodyFont).lineSpacing(3)
                    }
                case .quote(let quote):
                    Text(inline(quote))
                        .font(bodyFont)
                        .fontWeight(.medium)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Design.primary.opacity(0.5)).frame(width: 2)
                        }
                case .paragraph(let paragraph):
                    Text(inline(paragraph)).font(bodyFont).lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
