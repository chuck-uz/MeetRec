// Экран выбора локальной LLM с подсветкой пригодности под железо.
// Открывается «шестерёнкой» в шапке главного окна.
import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void

    private var recommendedID: String { LLMCatalog.recommended().id }

    var body: some View {
        // Читаем ревизию, чтобы список обновлялся после загрузки/удаления файлов.
        let _ = state.modelsRevision
        VStack(alignment: .leading, spacing: 12) {
            header
            hardwareCard
            ForEach(LLMCatalog.all) { model in
                ModelRow(model: model,
                         selected: state.llmModelID == model.id,
                         recommended: model.id == recommendedID)
            }
            Text("Модель работает локально; данные не покидают Mac. Выбранная модель "
                 + "скачается автоматически при первом чате, если ещё не загружена.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Design.primary)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .help("Назад")
            Text("Модель ИИ")
                .font(.headline)
            Spacer()
        }
    }

    private var hardwareCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(Design.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ваш Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Hardware.chipName) · \(Hardware.ramGB) ГБ памяти")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Design.primary.opacity(0.08))
        )
    }
}

private struct ModelRow: View {
    @EnvironmentObject var state: AppState
    let model: LLMModel
    let selected: Bool
    let recommended: Bool

    private var fit: LLMModel.Fit { model.fit(ramGB: Hardware.ramGB) }
    private var usable: Bool { fit != .insufficient }
    private var downloading: String? { state.modelDownloads[model.id] }
    private var downloaded: Bool { LLMCatalog.isDownloaded(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Design.primary : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.title)
                            .font(.callout.weight(.semibold))
                        Text("· \(String(format: "%.1f", model.fileGB)) ГБ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        badge
                    }
                    Text(model.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            downloadControls
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Design.corner)
                .fill(Color.primary.opacity(usable ? 0.05 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.corner)
                .stroke(selected ? Design.primary : .clear, lineWidth: 1.5)
        )
        .opacity(usable ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { if usable { state.selectLLM(model) } }
        .pointingCursor()
    }

    @ViewBuilder
    private var badge: some View {
        if !usable {
            label("Не хватит памяти", Design.destructive)
        } else if recommended {
            label("Рекомендуется", Design.accent)
        } else if fit == .tight {
            label("Впритык", Color.orange)
        } else {
            label("Доступно", Design.primary)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var downloadControls: some View {
        HStack(spacing: 8) {
            if let progress = downloading {
                ProgressView().controlSize(.mini)
                Text(progress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !usable {
                Text("нужно ≥ \(model.minRAMGB) ГБ памяти (у вас \(Hardware.ramGB))")
                    .font(.caption2)
                    .foregroundStyle(Design.destructive)
            } else if downloaded {
                Label("Загружено", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Design.accent)
                Spacer(minLength: 0)
                Button {
                    state.deleteModel(model)
                } label: {
                    Label("Удалить", systemImage: "trash")
                        .font(.caption2)
                }
                .controlSize(.mini)
                .pointingCursor()
                .help("Удалить файл модели, чтобы освободить \(String(format: "%.1f", model.fileGB)) ГБ")
            } else {
                Button {
                    state.downloadModel(model)
                } label: {
                    Label("Скачать сейчас", systemImage: "arrow.down.circle")
                        .font(.caption2)
                }
                .controlSize(.mini)
                .pointingCursor()
                .help("Скачать ~\(String(format: "%.1f", model.fileGB)) ГБ заранее")
                Spacer(minLength: 0)
                Text("иначе догрузится при первом чате")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
