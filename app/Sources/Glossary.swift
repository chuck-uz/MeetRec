// Словарь пользователя: термины, названия и фамилии, которые распознавание
// часто пишет на слух неверно. Подсказывается Whisper перед расшифровкой
// и модели, которая собирает итоги и отвечает в чате.
import Foundation

enum Glossary {
    static let key = "glossary"
    /// Whisper принимает подсказку не длиннее ~220 токенов; с запасом на кириллицу.
    static let promptLimit = 500

    static var text: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Слова через запятую или с новой строки.
    static var terms: [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Сколько слов из словаря помещается в подсказку распознаванию.
    static var termsInPrompt: Int {
        var length = 0
        var count = 0
        for term in terms {
            length += term.count + 2
            if length > promptLimit { break }
            count += 1
        }
        return count
    }

    /// Аргументы whisper-cli; пусто, если словарь не задан.
    static var whisperArguments: [String] {
        let used = terms.prefix(termsInPrompt)
        guard !used.isEmpty else { return [] }
        // --carry-initial-prompt: подсказка действует на всю запись, а не только на первые 30 секунд.
        return ["--prompt", "Глоссарий: " + used.joined(separator: ", ") + ".", "--carry-initial-prompt"]
    }

    /// Добавка к инструкции модели.
    static var llmNote: String {
        let all = terms
        guard !all.isEmpty else { return "" }
        return "\nПравильное написание терминов и имён, которые встречаются на этих встречах: "
            + all.prefix(300).joined(separator: ", ") + "."
    }
}
