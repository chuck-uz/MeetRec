// Фильтры распознавания: Whisper, обученный на субтитрах видео, на тишине, шуме и эхе
// «слышит» титры и зацикливается. Перенесено из meetvoice-kit (asr.py). Применяются к живым
// окнам (строго) и к итоговой расшифровке (бережно: настоящие реплики дороже чистоты).
import Foundation

struct LiveSegment {
    var start: Double
    var end: Double
    var text: String
    var lang: String
}

enum CaptionFilters {
    enum Mode {
        /// Короткие живые окна: лучше потерять реплику, чем показать мусор.
        case live
        /// Итоговая расшифровка (после VAD): убираем только явные титры и петли.
        case transcript
    }

    /// Титры с видео — в живой речи встречи их не бывает.
    private static let credits = try! NSRegularExpression(
        pattern: #"(субтитр\w*\s+(сделал|создавал|подготовил|делал)|редактор субтитров|продолжение следует|"#
            + #"спасибо за просмотр|подписывайтесь|ставьте лайк|thank(s| you) for watching|"#
            + #"amara\.org|go to the next (video|one)\b)"#,
        options: [.caseInsensitive])
    /// «Спасибо за внимание» — частая галлюцинация на тишине, но и настоящий конец доклада:
    /// в итоговой расшифровке оставляем.
    private static let liveOnly = try! NSRegularExpression(
        pattern: #"спасибо за внимание"#, options: [.caseInsensitive])
    private static let caption = try! NSRegularExpression(
        pattern: #"^\W*(\w+\s+)?(музыка|аплодисменты|смех|music|applause|laughter)\W*$"#,
        options: [.caseInsensitive])
    /// Иврит, японская кана, CJK, хангыль, арабский, тайский — на встречах их нет, это мусор.
    private static let farScript = try! NSRegularExpression(
        pattern: "[\u{0590}-\u{05FF}\u{3040}-\u{30FF}\u{3400}-\u{9FFF}\u{AC00}-\u{D7AF}\u{0600}-\u{06FF}\u{0E00}-\u{0E7F}]")
    private static let loneStock: Set<String> = ["thank you", "thanks"]
    /// Языки, для которых «дальние» алфавиты — норма, а не мусор.
    private static let farScriptLanguages: Set<String> = ["ja", "zh", "ko", "he", "yi", "ar", "fa", "ur", "ps", "th"]

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func norm(_ text: String) -> String {
        let cleaned = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) ? Character($0) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Обрезает петли декодера: фраза из 1…maxPhrase слов, повторённая больше keep раз.
    static func collapseRepeats(_ text: String, maxPhrase: Int = 8, keep: Int = 2) -> String {
        let words = text.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var collapsed = false
            for size in 1...maxPhrase where i + size <= words.count {
                let chunk = Array(words[i..<(i + size)])
                var reps = 1
                while i + (reps + 1) * size <= words.count,
                      Array(words[(i + reps * size)..<(i + (reps + 1) * size)]) == chunk {
                    reps += 1
                }
                if reps > keep {
                    for _ in 0..<keep { out += chunk }
                    i += reps * size
                    collapsed = true
                    break
                }
            }
            if !collapsed {
                out.append(words[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Чистит сегменты окна (или всей записи) длительностью `duration` секунд.
    /// `lang` — язык, определённый Whisper (нужен, чтобы не выкинуть японский как мусор).
    static func clean(
        _ segments: [LiveSegment], duration: Double, mode: Mode = .live, lang: String = "", maxSame: Int = 2
    ) -> [LiveSegment] {
        let live = mode == .live
        let checkFarScript = !farScriptLanguages.contains(lang)
        var out: [LiveSegment] = []
        var run = 0
        for var segment in segments {
            let text = collapseRepeats(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty,
                  !text.hasPrefix("Глоссарий:"), // на тишине Whisper может повторить подсказку-словарь
                  !matches(credits, text), !matches(caption, text),
                  !(checkFarScript && matches(farScript, text)),
                  !(live && matches(liveOnly, text)),
                  !(live && loneStock.contains(norm(text))),
                  segment.start < duration // петля уводит метки за конец звука
            else { continue }
            segment.text = text
            segment.end = min(segment.end, duration)
            let key = norm(text)
            let same = out.last.map { norm($0.text) == key } ?? false
            run = same ? run + 1 : 1
            // Петля, размазанная по сегментам. В расшифровке короткие «Да.» подряд от разных
            // людей — норма, поэтому там считаем только фразы от трёх слов.
            if run > maxSame, live || key.split(separator: " ").count >= 3 { continue }
            out.append(segment)
        }
        return out
    }
}
