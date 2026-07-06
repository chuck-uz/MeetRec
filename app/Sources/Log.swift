// Простой файловый лог MeetRec — чтобы пользователь мог прислать логи при ошибке.
// Файл: ~/Library/Logs/MeetRec/MeetRec.log
import AppKit
import Foundation

enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MeetRec")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MeetRec.log")
    }()

    private static let queue = DispatchQueue(label: "meetrec.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write(message, level: "INFO") }
    static func error(_ message: String) { write(message, level: "ERROR") }

    static func write(_ message: String, level: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Ограничивает файл лога, чтобы не рос бесконечно (оставляем последние ~256 КБ).
    static func trimIfNeeded() {
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int, size > 512_000,
                  let data = try? Data(contentsOf: fileURL) else { return }
            let tail = data.suffix(256_000)
            try? tail.write(to: fileURL)
        }
    }

    /// Открыть файл лога в Finder (выделить), чтобы пользователь мог его прислать.
    @MainActor static func reveal() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "".data(using: .utf8)?.write(to: fileURL)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
