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

            if Hardware.supportsChat {
                section("Модель ИИ") {
                    ModelSettingsView(onBack: nil)
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
