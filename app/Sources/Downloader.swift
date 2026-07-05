// Общий загрузчик больших файлов (модели Whisper/LLM) с прогрессом.
import Foundation

enum Downloader {
    static func fetch(
        from source: URL, to dest: URL,
        label: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetRecError("Не удалось скачать \(label). Проверьте интернет.")
        }
        let expected = response.expectedContentLength
        let tmp = dest.appendingPathExtension("download")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(4 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (4 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    progress("\(label): \(Int(Double(written) / Double(expected) * 100))%")
                }
            }
        }
        try handle.write(contentsOf: buffer)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
