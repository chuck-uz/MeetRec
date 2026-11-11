// Калибровка порогов библиотеки голосов на своих записях:
//   MeetRec --voice-calibrate <папка записей> <отчёт.txt> [число записей]
// Для каждой записи: диаризация, отпечатки каждой метки по двум половинам её реплик
// (чётные / нечётные). Сходство половин одной метки — «тот же человек в одной встрече»,
// разных меток одной встречи — «разные люди» (или один человек, разрезанный диаризацией),
// между встречами — смесь: высокие пары там обычно сам владелец записи.
// Звук и отпечатки никуда не уходят; в отчёт попадают только числа.
import Foundation

enum VoiceCalibration {
    static func run(folder: URL, report: URL, limit: Int) async {
        var out: [String] = []
        func say(_ line: String) {
            out.append(line)
            try? out.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .compactMap { url -> (URL, Double)? in
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return (url, Double(size))
            }
            .filter { $0.1 > 15e6 && $0.1 < 45e6 } // ~15–35 мин при 160 кбит/с
            .sorted { $0.0.lastPathComponent > $1.0.lastPathComponent }
            .prefix(limit)
            .map(\.0)
        say("записей: \(files.count)")

        var prints: [(meeting: Int, label: String, half: String, print: VoicePrint)] = []
        let service = DiarizationService.shared
        for (m, file) in files.enumerated() {
            let wav = fm.temporaryDirectory.appendingPathComponent("meetrec-cal-\(UUID().uuidString).wav")
            defer { try? fm.removeItem(at: wav) }
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file.path, wav.path]
            do {
                try convert.run()
                convert.waitUntilExit()
                let samples = try service.loadSamples(wav: wav)
                let speakers = try await service.diarize(wav: wav) { _ in }
                let embed = try await service.embedder { _ in }
                var lines: [VoiceLine] = []
                var counter: [String: Int] = [:]
                for s in speakers {
                    let n = counter[s.speaker, default: 0]
                    counter[s.speaker] = n + 1
                    lines.append(VoiceLine(start: s.start, end: s.end, speaker: s.speaker + (n % 2 == 0 ? "#A" : "#B")))
                }
                let found = VoicePrints.compute(tracks: ["mix": samples], lines: lines, embed: embed)
                for (key, print) in found {
                    let parts = key.split(separator: "#")
                    prints.append((m, String(parts[0]), String(parts[1]), print))
                }
                say("встреча \(m + 1): \(Int(Double(samples.count) / 16_000 / 60)) мин, меток \(Set(speakers.map(\.speaker)).count), с отпечатками \(Set(found.keys.map { $0.split(separator: "#")[0] }).count)")
            } catch {
                say("встреча \(m + 1): ошибка \(error.localizedDescription)")
            }
        }

        var same: [Float] = [], differentInMeeting: [Float] = [], crossMeeting: [Float] = []
        for i in prints.indices {
            for j in prints.indices where j > i {
                let a = prints[i], b = prints[j]
                let score = VoiceMath.dot(a.print.emb, b.print.emb)
                if a.meeting == b.meeting {
                    if a.label == b.label { same.append(score) }
                    else if a.half == "A", b.half == "A" { differentInMeeting.append(score) }
                } else if a.half == "A", b.half == "A" {
                    crossMeeting.append(score)
                }
            }
        }
        func describe(_ name: String, _ values: [Float]) {
            guard !values.isEmpty else { say("\(name): нет пар"); return }
            let s = values.sorted()
            func q(_ p: Double) -> String { String(format: "%.2f", s[min(s.count - 1, Int(p * Double(s.count - 1)))]) }
            say("\(name): пар \(s.count) · мин \(q(0)) · 10% \(q(0.1)) · медиана \(q(0.5)) · 90% \(q(0.9)) · макс \(q(1))")
        }
        say("")
        describe("одна метка, две половины встречи", same)
        describe("разные метки одной встречи", differentInMeeting)
        describe("метки разных встреч", crossMeeting)
        let histogram = stride(from: Float(0), to: 1, by: 0.1).map { low in
            "\(String(format: "%.1f", low))–\(String(format: "%.1f", low + 0.1)): \(crossMeeting.filter { $0 >= low && $0 < low + 0.1 }.count)"
        }
        say("между встречами по корзинам: " + histogram.joined(separator: " · "))
        say("готово")
    }
}
