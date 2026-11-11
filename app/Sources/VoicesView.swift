// Говорящие встречи (переименование, «узнан по голосу») и управление библиотекой голосов.
import SwiftUI

/// Список говорящих встречи: назвать, исправить, подтвердить имя, данное по голосу.
struct SpeakersList: View {
    @EnvironmentObject var state: AppState
    let audio: URL
    let speakers: [AppState.SpeakerInfo]

    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if speakers.isEmpty {
                Text("В расшифровке нет разметки по говорящим. Включите «Говорящие» перед записью — реплики будут подписаны.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(speakers) { row($0) }
            if !speakers.isEmpty, !state.voiceLibrary {
                Text("Имена сохранятся в расшифровке. Чтобы MeetRec узнавал этих людей в следующих встречах, включите «Голоса» перед записью.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ speaker: AppState.SpeakerInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing == speaker.label {
                TextField("Имя", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit(speaker.label) }
                HStack(spacing: 6) {
                    Button("Сохранить") { commit(speaker.label) }
                        .keyboardShortcut(.defaultAction)
                    Button("Отмена") { editing = nil }
                }
            } else {
                HStack(spacing: 6) {
                    Text(speaker.label)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(speaker.turns) репл.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if speaker.recognized != nil {
                        Button("Верно") { state.confirmSpeaker(in: audio, speaker.label) }
                            .help("Имя подтверждено — убрать отметку")
                    }
                    Button(speaker.recognized != nil ? "Исправить" : "Назвать") {
                        draft = VoicePrints.isGeneric(speaker.label) ? "" : speaker.label
                        editing = speaker.label
                    }
                }
                if let match = speaker.recognized {
                    Text("узнан по голосу · сходство \(String(format: "%.2f", match.score))")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Design.primary.opacity(0.12)))
                        .foregroundStyle(Design.primary)
                }
            }
            if !speaker.sample.isEmpty {
                Text("«\(speaker.sample)»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .controlSize(.small)
    }

    private func commit(_ label: String) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !name.isEmpty else { return }
        state.renameSpeaker(in: audio, from: label, to: name)
    }
}

/// Список запомненных голосов: переименовать, забыть, удалить всё.
struct VoicesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    /// Страница в главном окне (а не лист): без кнопки «Готово» и фиксированной ширины.
    var embedded = false

    @State private var voices: [VoiceLibrary.Voice] = []
    @State private var editing: String?
    @State private var draft = ""
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Голоса")
                .font(.system(size: 22, design: .serif))
            Text("Отпечатки голосов людей, которых вы назвали во встречах. Хранятся только на этом Mac, без звука. Отпечаток голоса — биометрические данные: храните их с согласия участников.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if voices.isEmpty {
                Text("Пока пусто. Откройте встречу, назовите говорящих на вкладке «Говорящие» — голоса запомнятся.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(voices) { voice in
                    HStack {
                        if editing == voice.name {
                            TextField("Имя", text: $draft)
                                .onSubmit { commit(voice.name) }
                            Button("Сохранить") { commit(voice.name) }
                            Button("Отмена") { editing = nil }
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(voice.name)
                                Text("встреч: \(voice.meetings) · речи \(Int(voice.seconds)) с")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Переименовать") {
                                draft = voice.name
                                editing = voice.name
                            }
                            Button("Забыть", role: .destructive) { state.forgetVoice(voice.name) }
                        }
                    }
                    .controlSize(.small)
                }
                .frame(minHeight: embedded ? 320 : 160)
            }

            HStack {
                if !voices.isEmpty {
                    Button("Забыть все голоса…", role: .destructive) { confirmForgetAll = true }
                }
                Spacer()
                if !embedded {
                    Button("Готово") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(embedded ? 0 : 18)
        .frame(width: embedded ? nil : 460)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: state.speakersRevision) {
            voices = await VoiceLibrary.shared.voices()
        }
        .confirmationDialog("Удалить все отпечатки голосов?", isPresented: $confirmForgetAll) {
            Button("Забыть все", role: .destructive) { state.forgetAllVoices() }
        } message: {
            Text("Имена в уже готовых транскриптах останутся. Отменить нельзя.")
        }
    }

    private func commit(_ old: String) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !name.isEmpty, name != old else { return }
        state.renameVoice(old, to: name)
    }
}
