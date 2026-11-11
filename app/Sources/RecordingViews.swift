// Экраны записи: «Новая запись» (что включить для этой встречи) и идущая запись
// с живыми субтитрами в рабочей области.
import SwiftUI

struct NewRecordingView: View {
    @EnvironmentObject var state: AppState
    @State private var voiceConsentVisible = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Что записываем?")
                .font(.system(size: 26, design: .serif))
            if let message = state.errorMessage {
                ErrorBanner(message: message).frame(maxWidth: 520)
            }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetingTitle)
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Text(meetingHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Chip(title: "Субтитры", icon: "captions.bubble", isOn: state.liveCaptions) {
                        state.liveCaptions.toggle()
                    }
                    .help("Живые субтитры с переводом иностранной речи")
                    Chip(title: "Говорящие", icon: "person.2", isOn: state.diarize) {
                        state.diarize.toggle()
                        if !state.diarize { state.voiceLibrary = false }
                    }
                    .help("Расшифровка как диалог: «Я», «Спикер 1»…")
                    Chip(title: "Голоса", icon: "person.wave.2", isOn: state.voiceLibrary) {
                        if state.voiceLibrary { state.voiceLibrary = false } else { voiceConsentVisible = true }
                    }
                    .help("Узнавать людей по голосу из прошлых встреч")
                    if Hardware.supportsChat {
                        Chip(title: "Итоги", icon: "list.bullet.rectangle", isOn: state.autoSummary) {
                            state.autoSummary.toggle()
                        }
                        .help("После записи: кратко, решения, задачи")
                    }
                    Chip(title: "Видео", icon: "video", isOn: state.captureVideo) {
                        state.captureVideo.toggle()
                    }
                    .help("Записывать экран или окно вместе со звуком")
                    Spacer(minLength: 8)
                    if state.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        PillButton(title: "Записать", icon: "circle.fill", color: Design.destructive) {
                            state.requestStart()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))

            Text(footnote)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Узнавать людей по голосу?", isPresented: $voiceConsentVisible) {
            Button("Включить") {
                state.voiceLibrary = true
                state.diarize = true
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("MeetRec запомнит отпечатки голосов людей, которых вы назовёте во встречах, и будет подставлять их имена в следующих. Отпечаток голоса — биометрические персональные данные: он хранится только на этом Mac, без звука, и его можно забыть в любой момент. Предупреждайте участников, как и о самой записи.")
        }
    }

    private var meetingTitle: String {
        state.currentMeeting?.title ?? "Новая встреча"
    }

    private var meetingHint: String {
        if state.currentMeeting != nil { return "название из календаря — встреча идёт сейчас" }
        if let next = state.nextMeeting {
            return "следующая в календаре: \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)"
        }
        return state.calendarConnected
            ? "запись получит название по дате и времени"
            : "подключите календарь в настройках — записи будут называться по встречам"
    }

    private var footnote: String {
        let language = AppState.languageOptions.first { $0.code == state.transcribeLanguage }?.title ?? "Авто"
        var parts = [language, Transcriber.modelTitle]
        if Hardware.supportsChat { parts.append(LLMSpec.current.title) }
        parts.append("папка «\(state.outputDir.lastPathComponent)»")
        return parts.joined(separator: " · ")
    }
}

struct LiveRecordingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if state.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .fill(state.isPaused ? Color.secondary : Design.destructive)
                        .frame(width: 10, height: 10)
                }
                Text(state.currentMeeting?.title ?? "Новая встреча")
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.elapsedText)
                    .font(.system(size: 17, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 12)
            Rectangle().fill(Design.hairline).frame(height: 1)

            if let message = state.errorMessage {
                ErrorBanner(message: message).padding(16)
            }
            if let captioner = state.captioner {
                LiveCaptionsStream(captioner: captioner)
            } else {
                noCaptions
            }
            controls
        }
    }

    private var statusText: String {
        if state.isSaving { return "сводим дорожки и сохраняем…" }
        if state.isPaused { return "пауза — простой не попадёт в запись" }
        if let size = state.recordingSizeText { return "идёт запись · видео \(size)" }
        return "идёт запись"
    }

    private var noCaptions: some View {
        VStack(spacing: 8) {
            Text(state.elapsedText)
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
            Text("Живые субтитры выключены. Расшифровка появится после остановки записи.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if state.captioner != nil {
                CaptionsModePicker()
                Chip(title: "Поверх экрана", icon: "pip") { state.showCaptions() }
                    .help("Показать субтитры в окне поверх всех окон — удобно во время звонка")
            }
            Spacer()
            if !state.isSaving {
                Chip(title: state.isPaused ? "Продолжить" : "Пауза",
                     icon: state.isPaused ? "play.fill" : "pause.fill") { state.pauseResume() }
                PillButton(title: "Остановить", icon: "stop.fill") { state.stopAndSave() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Переключатель «оба / перевод / оригинал» — общий с окном поверх экрана.
struct CaptionsModePicker: View {
    @AppStorage("captionsMode") private var mode = CaptionsMode.both.rawValue

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptionsMode.allCases, id: \.rawValue) { item in
                Chip(title: item.rawValue, isOn: mode == item.rawValue) { mode = item.rawValue }
                    .help(item.help)
            }
        }
    }
}

/// Лента живых субтитров в рабочей области: новые реплики снизу.
private struct LiveCaptionsStream: View {
    @ObservedObject var captioner: LiveCaptioner
    @AppStorage("captionsMode") private var mode = CaptionsMode.both.rawValue

    private var currentMode: CaptionsMode { CaptionsMode(rawValue: mode) ?? .both }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if captioner.entries.isEmpty {
                        Text(captioner.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(captioner.entries) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: captioner.entries) {
                if let last = captioner.entries.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let error = captioner.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(12)
                    .help(error)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: CaptionEntry) -> some View {
        let foreign = !entry.target.isEmpty && (entry.translation == nil || entry.shownTranslation != nil)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.speaker) · \(LiveCaptioner.clock(entry.start))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if !foreign || currentMode != .translation || entry.translation == nil {
                Text(entry.text)
                    .font(foreign && currentMode == .both ? .system(size: 13).italic() : .system(size: 16))
                    .foregroundStyle(entry.isMe || (foreign && currentMode == .both) ? Color.secondary : Color.primary)
            }
            if foreign, currentMode != .original {
                if let translation = entry.shownTranslation {
                    Text(translation).font(.system(size: 16, weight: .medium))
                } else {
                    Text("перевожу…").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
        }
        .textSelection(.enabled)
    }
}
