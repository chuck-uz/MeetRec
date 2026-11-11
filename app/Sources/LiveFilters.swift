// Фильтры распознавания коротких живых окон: Whisper, обученный на субтитрах видео,
// на тишине, шуме и эхе «слышит» титры и зацикливается. Перенесено из meetvoice-kit (asr.py).
import Foundation

struct LiveSegment {
    var start: Double
    var end: Double
    var text: String
    var lang: String
}

enum CaptionFilters {
    private static let hallucination = try! NSRegularExpression(
        pattern: #"(субтитр\w*\s+(сделал|создавал|подготовил|делал)|редактор субтитров|продолжение следует|"#
            + #"спасибо за (просмотр|внимание)|подписывайтесь|ставьте лайк|thank(s| you) for watching|"#
            + #"amara\.org|go to the next (video|one)\b)"#,
        options: [.caseInsensitive])
    private static let caption = try! NSRegularExpression(
        pattern: #"^\W*(\w+\s+)?(музыка|аплодисменты|смех|music|applause|laughter)\W*$"#,
        options: [.caseInsensitive])
    /// Иврит, японская кана, CJK, хангыль, арабский, тайский — на встречах их нет, это мусор.
    private static let farScript = try! NSRegularExpression(
        pattern: "[\u{0590}-\u{05FF}\u{3040}-\u{30FF}\u{3400}-\u{9FFF}\u{AC00}-\u{D7AF}\u{0600}-\u{06FF}\u{0E00}-\u{0E7F}]")
    private static let loneStock: Set<String> = ["thank you", "thanks"]

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

    /// Чистит сегменты одного окна длительностью `duration` секунд.
    static func clean(_ segments: [LiveSegment], duration: Double, maxSame: Int = 2) -> [LiveSegment] {
        var out: [LiveSegment] = []
        var run = 0
        for var segment in segments {
            let text = collapseRepeats(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty,
                  !matches(hallucination, text), !matches(caption, text), !matches(farScript, text),
                  !loneStock.contains(norm(text)),
                  segment.start < duration // петля на коротком окне уводит метки за конец звука
            else { continue }
            segment.text = text
            segment.end = min(segment.end, duration)
            let same = out.last.map { norm($0.text) == norm(text) } ?? false
            run = same ? run + 1 : 1
            if run > maxSame { continue }
            out.append(segment)
        }
        return out
    }
}
