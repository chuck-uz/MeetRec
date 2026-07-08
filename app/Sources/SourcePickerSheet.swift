// Диалог выбора источника видео перед началом записи:
// весь экран, конкретный монитор или отдельное окно (живой список).
import SwiftUI

struct SourcePickerSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "record.rectangle")
                    .foregroundStyle(Design.destructive)
                Text("Что записывать?")
                    .font(.headline)
                Spacer()
                Button {
                    state.refreshSourceOptions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .pointingCursor()
                .help("Обновить список окон")
            }

            Text("Звук встречи пишется полностью в любом случае — даже если снимаете другое окно.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.sourceOptions) { option in
                        row(option)
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Button("Отмена") { state.cancelSourceSheet() }
                    .keyboardShortcut(.cancelAction)
                    .pointingCursor()
                Spacer()
                Button {
                    state.confirmSourceSheet()
                } label: {
                    Label("Начать запись", systemImage: "record.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Design.destructive)
                .pointingCursor()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ option: CaptureSourceOption) -> some View {
        let selected = option.source == state.videoSource
        return Button {
            state.videoSource = option.source
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Design.primary : Color.secondary)
                Image(systemName: option.kind == .display ? "display" : "macwindow")
                    .foregroundStyle(Design.primary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Design.primary.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}
