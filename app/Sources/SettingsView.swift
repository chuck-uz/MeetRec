// Настройки: всё, что задаётся один раз, а не для каждой записи.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Настройки")
                .font(.system(size: 22, design: .serif))

            section("Запись") {
                row("Папка записей", detail: state.outputDir.path.contains("/CloudStorage/GoogleDrive-")
                    ? "Google Диск · \(state.outputDir.lastPathComponent)" : state.outputDir.lastPathComponent) {
                    Button("Открыть") { state.openFolder() }
                    Button("Изменить…") { state.chooseFolder() }
                }
                toggleRow("Расшифровывать после записи", detail: Transcriber.modelTitle + (state.modelStatus.map { " · \($0)" } ?? ""),
                          isOn: $state.autoTranscribe)
                row("Язык распознавания", detail: "он же — язык, на который переводятся субтитры") {
                    Picker("", selection: $state.transcribeLanguage) {
                        ForEach(AppState.languageOptions, id: \.code) { option in
                            Text(option.title).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            section("Словарь") {
                GlossarySettings()
            }

            section("Календарь") {
                row("Google Календарь", detail: calendarDetail) {
                    if state.calendarConfigured {
                        if state.calendarConnected {
                            Button("Отключить") { state.disconnectCalendar() }
                        } else {
                            Button("Подключить") { state.connectCalendar() }
                                .disabled(state.calendarStatus != nil)
                        }
                    }
                }
            }

            section("Модель ИИ") {
                row("Где работает ИИ", detail: "итоги, чат, поиск по встречам и перевод субтитров") {
                    Picker("", selection: $state.llmBackend) {
                        Text("На этом Mac").tag("local")
                        ForEach(CloudProvider.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let provider = CloudProvider(rawValue: state.llmBackend) {
                    CloudModelSettings(provider: provider).id(provider)
                } else if Hardware.supportsChat {
                    ModelSettingsView(onBack: nil)
                        .padding(.vertical, 10)
                } else {
                    Text("Локальной модели нужен Mac с 16+ ГБ памяти (у вас \(Hardware.ramGB)). "
                         + "Выберите внешнюю модель и добавьте её API-ключ.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }

            section("Приложение") {
                toggleRow("Запускать при входе в систему", isOn: $state.launchAtLogin)
                toggleRow("Окно поверх всех окон", isOn: $state.floatOnTop)
                row("Версия \(UpdateChecker.currentVersion)", detail: state.availableUpdate.map { "доступна \($0.version)" }) {
                    if state.availableUpdate != nil {
                        Button("Обновить") { state.openLatestRelease() }
                    }
                    Button("Проверить обновления") { state.checkForUpdates(manual: true) }
                }
                row("Журнал работы", detail: "пригодится, если что-то пошло не так") {
                    Button("Показать логи") { state.openLogs() }
                }
                row("Завершить MeetRec", detail: state.isRecording ? "запись будет остановлена и сохранена" : nil) {
                    Button("Завершить") { state.quit() }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendarDetail: String {
        if let status = state.calendarStatus { return status }
        if !state.calendarConfigured { return "нет google_oauth.json — см. README" }
        return state.calendarConnected
            ? "записи называются по встречам, участники попадают в расшифровку"
            : "автоназвание записей по встречам"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Rectangle().fill(Design.hairline).frame(height: 1)
            content()
        }
    }

    private func row<Trailing: View>(
        _ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.vertical, 10)
            Rectangle().fill(Design.hairline).frame(height: 1)
        }
    }

    private func toggleRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Design.primary)
        }
    }
}

/// Ключ и модель внешнего провайдера.
private struct CloudModelSettings: View {
    @EnvironmentObject var state: AppState
    let provider: CloudProvider
    @State private var key = ""
    @State private var model = ""
    @State private var hasKey = false
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("API-ключ").font(.system(size: 13.5)).frame(width: 80, alignment: .leading)
                SecureField(hasKey ? "сохранён в Связке ключей\(keyTail)" : "вставьте ключ", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    // Сохраняем сразу, как только ключ вставлен: переключение провайдера
                    // или уход с экрана его не теряют.
                    .onChange(of: key) { autosave() }
                Button("Сохранить", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Удалить") {
                        try? provider.setKey("")
                        refresh()
                    }
                } else {
                    Button("Получить…") { NSWorkspace.shared.open(provider.keysPage) }
                        .help("Открыть страницу ключей \(provider.title) в браузере")
                }
            }
            HStack(spacing: 8) {
                Text("Модель").font(.system(size: 13.5)).frame(width: 80, alignment: .leading)
                TextField(provider.models[0], text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveModel)
                    .onChange(of: model) { saveModel() }
                Menu("Выбрать") {
                    ForEach(provider.models, id: \.self) { name in
                        Button(name) { model = name }
                    }
                }
                .fixedSize()
                Button(checking ? "Проверяю…" : "Проверить") { check() }
                    .disabled(!hasKey || checking)
                    .help("Отправить короткий запрос: проверит ключ и название модели")
            }
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(result.ok ? Design.accent : Design.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Расшифровки, вопросы и реплики для перевода будут отправляться в \(provider.company) "
                 + "и оплачиваться по тарифам провайдера. Запись звука, распознавание речи, голоса и поисковый "
                 + "индекс остаются на этом Mac. Ключ хранится в Связке ключей macOS.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .onAppear(perform: refresh)
    }

    /// Последние символы сохранённого ключа — чтобы было видно, какой именно ключ лежит.
    private var keyTail: String {
        let _ = hasKey
        guard let saved = provider.apiKey, saved.count >= 12 else { return "" }
        return " · …\(saved.suffix(4))"
    }

    private func autosave() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return }
        do {
            try provider.setKey(trimmed)
            hasKey = true
            state.cloudRevision += 1
        } catch {
            result = (false, error.localizedDescription)
        }
    }

    private func refresh() {
        hasKey = provider.hasKey
        model = provider.model
        key = ""
        result = nil
        state.cloudRevision += 1
    }

    private func save() {
        do {
            try provider.setKey(key)
            refresh()
            check()
        } catch {
            result = (false, error.localizedDescription)
        }
    }

    private func saveModel() {
        guard provider.model != model.trimmingCharacters(in: .whitespaces) || model.isEmpty else { return }
        provider.model = model
        result = nil
        state.cloudRevision += 1
    }

    private func check() {
        checking = true
        result = nil
        Task {
            do {
                try await CloudLLM.check(provider)
                result = (true, "Работает: \(provider.title) · \(provider.model)")
            } catch {
                result = (false, error.localizedDescription)
            }
            checking = false
        }
    }
}

/// Термины и имена, которые распознавание должно писать правильно.
private struct GlossarySettings: View {
    @State private var text = Glossary.text

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Термины, названия систем и фамилии, которые распознавание пишет на слух неверно. "
                 + "Через запятую или с новой строки, в правильном написании.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .onChange(of: text) { Glossary.text = text }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var hint: String {
        let _ = text
        let total = Glossary.terms.count
        if total == 0 { return "Например: PostgreSQL, MariaDB, Kubernetes, GitLab. Действует на новые расшифровки, субтитры, итоги и чат." }
        let used = Glossary.termsInPrompt
        return used < total
            ? "Слов: \(total). Распознаванию помещаются первые \(used) — самые важные ставьте в начало. Итоги и чат учитывают все."
            : "Слов: \(total). Действует на новые расшифровки, субтитры, итоги и чат."
    }
}
