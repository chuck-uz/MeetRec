// Говорящие встречи (переименование, «узнан по голосу») и управление библиотекой голосов.
import SwiftUI

/// Раздел «Говорящие» у записи в «Мои встречи».
struct SpeakersSection: View {
    @EnvironmentObject var state: AppState
    let audio: URL

    @State private var speakers: [AppState.SpeakerInfo] = []
    @State private var expanded = false
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        Group {
            if speakers.count > 0 {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(speakers) { row($0) }
                        if !state.voiceLibrary {
                            Text("Имена сохранятся в транскрипте. Чтобы MeetRec узнавал этих людей в следующих встречах, включите «Узнавать по голосу» в главном окне.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Text("Говорящие")
                            .font(.callout.weight(.medium))
                        Text(speakers.map(\.label).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if speakers.contains(where: { $0.recognized != nil }) {
                            Image(systemName: "waveform.badge.checkmark")
                                .foregroundStyle(Design.accent)
                                .help("Есть имена, данные по голосу — проверьте их")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
        }
        .task(id: "\(audio.path)#\(state.speakersRevision)#\(state.transcribeProgress[audio] ?? "")") {
            speakers = await state.speakers(in: audio)
            if speakers.contains(where: { $0.recognized != nil }) { expanded = true }
        }
    }

    @ViewBuilder
    private func row(_ speaker: AppState.SpeakerInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if editing == speaker.label {
                    HStack(spacing: 6) {
                        TextField("Имя", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit { commit(speaker.label) }
                        Button("Сохранить") { commit(speaker.label) }
                            .keyboardShortcut(.defaultAction)
                        Button("Отмена") { editing = nil }
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Text(speaker.label)
                            .font(.callout.weight(.medium))
                        Text("\(speaker.turns) репл.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let match = speaker.recognized {
                            Text("узнан по голосу · сходство \(String(format: "%.2f", match.score))")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Design.accent.opacity(0.15)))
                                .foregroundStyle(Design.accent)
                        }
                    }
                }
                if !speaker.sample.isEmpty {
                    Text("«\(speaker.sample)»")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if editing != speaker.label {
                if speaker.recognized != nil {
                    Button("Верно") { state.confirmSpeaker(in: audio, speaker.label) }
                        .help("Имя подтверждено — убрать отметку")
                        .pointingCursor()
                }
                Button(speaker.recognized != nil ? "Исправить" : "Назвать") {
                    draft = VoicePrints.isGeneric(speaker.label) ? "" : speaker.label
                    editing = speaker.label
                }
                .pointingCursor()
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

    @State private var voices: [VoiceLibrary.Voice] = []
    @State private var editing: String?
    @State private var draft = ""
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Голоса")
                .font(.title3.weight(.semibold))
            Text("Отпечатки голосов людей, которых вы назвали во встречах. Хранятся только на этом Mac, без звука. Отпечаток голоса — биометрические данные: храните их с согласия участников.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if voices.isEmpty {
                Text("Пока пусто. Назовите говорящих у записи в «Мои встречи» — голоса запомнятся.")
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
                .frame(minHeight: 160)
            }

            HStack {
                if !voices.isEmpty {
                    Button("Забыть все голоса…", role: .destructive) { confirmForgetAll = true }
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
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
