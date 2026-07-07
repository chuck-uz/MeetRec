// Каталог локальных LLM для чата/итогов и подбор под железо.
// На Apple Silicon память общая (CPU+GPU), поэтому единственный реальный
// ограничитель — объём unified memory (Hardware.ramGB). Для каждой модели
// заданы два порога: minRAMGB (жёсткий пол) и comfortRAMGB (комфортно).
import Foundation

/// Одна модель в каталоге выбора.
struct LLMModel: Identifiable, Sendable {
    let id: String          // стабильный идентификатор (qwen7b…)
    let title: String       // как показываем пользователю
    let file: String        // имя .gguf в каталоге моделей
    let url: String          // откуда качать
    let quant: String       // квантизация (для подписи)
    let fileGB: Double      // размер загрузки, ГБ
    let minRAMGB: Int       // ниже — не запускать (не влезет)
    let comfortRAMGB: Int   // от этого объёма работает с запасом
    let blurb: String       // короткое описание качества/скорости

    /// Как модель ложится на данный объём памяти.
    enum Fit { case comfortable, tight, insufficient }

    func fit(ramGB: Int) -> Fit {
        if ramGB < minRAMGB { return .insufficient }
        if ramGB < comfortRAMGB { return .tight }
        return .comfortable
    }

    var spec: LLMSpec { LLMSpec(file: file, url: url, title: title) }
}

enum LLMCatalog {
    /// Пороги подобраны под llama.cpp Q4_K_M + контекст 16К на Apple Silicon,
    /// с учётом что чат ждёт окончания транскрибации (не конкурирует с Whisper).
    static let all: [LLMModel] = [
        LLMModel(
            id: "qwen3b",
            title: "Qwen 2.5 3B",
            file: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            url: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            quant: "Q4_K_M", fileGB: 2.0, minRAMGB: 8, comfortRAMGB: 8,
            blurb: "Лёгкая и быстрая. Для базовых итогов на Mac с 8–16 ГБ."),
        LLMModel(
            id: "qwen7b",
            title: "Qwen 2.5 7B",
            file: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            url: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            quant: "Q4_K_M", fileGB: 4.7, minRAMGB: 12, comfortRAMGB: 16,
            blurb: "Стандарт: хороший баланс качества и скорости. Для 16 ГБ+."),
        LLMModel(
            id: "qwen14b",
            title: "Qwen 2.5 14B",
            file: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
            url: "https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf",
            quant: "Q4_K_M", fileGB: 9.0, minRAMGB: 16, comfortRAMGB: 24,
            blurb: "Максимальное качество итогов и рассуждений. Для 24 ГБ+."),
    ]

    static func model(id: String) -> LLMModel? { all.first { $0.id == id } }
    static func model(file: String) -> LLMModel? { all.first { $0.file == file } }

    /// Лучшая модель, которая работает на этом железе с запасом; если ни одна
    /// не комфортна — самая мощная из хотя бы запускающихся; иначе самая лёгкая.
    static func recommended(ramGB: Int = Hardware.ramGB) -> LLMModel {
        if let best = all.last(where: { ramGB >= $0.comfortRAMGB }) { return best }
        if let any = all.last(where: { ramGB >= $0.minRAMGB }) { return any }
        return all.first!
    }

    /// Модель по умолчанию (пользователь не выбирал сам): рекомендованная под
    /// железо. Но если рекомендованная ещё не скачана, а какая-то подходящая уже
    /// есть на диске — берём её, чтобы не заставлять качать большую модель тех,
    /// у кого уже что-то работает.
    static func defaultModel(ramGB: Int = Hardware.ramGB) -> LLMModel {
        let rec = recommended(ramGB: ramGB)
        if isDownloaded(rec) { return rec }
        if let downloaded = all.last(where: { isDownloaded($0) && ramGB >= $0.minRAMGB }) {
            return downloaded
        }
        return rec
    }

    /// Сейчас активная модель: явный выбор пользователя, иначе — модель по умолчанию.
    static var current: LLMModel {
        if userChosen, let id = UserDefaults.standard.string(forKey: "llmModelID"),
           let m = model(id: id) { return m }
        return defaultModel()
    }

    /// Пользователь выбрал модель вручную — фиксируем и защищаем от манифеста.
    static func choose(_ model: LLMModel) {
        let d = UserDefaults.standard
        d.set(model.id, forKey: "llmModelID")
        d.set(model.file, forKey: "llmModelFile")
        d.set(model.url, forKey: "llmModelURL")
        d.set(model.title, forKey: "llmModelTitle")
        d.set(true, forKey: "llmModelUserChosen")
    }

    static var userChosen: Bool { UserDefaults.standard.bool(forKey: "llmModelUserChosen") }

    /// Модель уже скачана?
    static func isDownloaded(_ model: LLMModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(model).path)
    }

    static func fileURL(_ model: LLMModel) -> URL {
        Transcriber.modelsDir.appendingPathComponent(model.file)
    }

    /// Фактический размер на диске, если скачана.
    static func downloadedBytes(_ model: LLMModel) -> Int64? {
        let path = fileURL(model).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}
