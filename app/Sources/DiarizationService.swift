// Локальная диаризация («кто говорил») через FluidAudio (CoreML, pyannote-модели).
import AVFoundation
import FluidAudio
import Foundation

final class DiarizationService {
    static let shared = DiarizationService()

    struct SpeakerSegment {
        let speaker: String // «Спикер 1», «Спикер 2»…
        let start: Double
        let end: Double
    }

    private var manager: DiarizerManager?

    /// Диаризация wav-файла (16 кГц моно). Возвращает таймлайн говорящих.
    func diarize(wav: URL, progress: @escaping @Sendable (String) -> Void) async throws -> [SpeakerSegment] {
        let manager = try await prepared(progress: progress)
        let samples = try loadSamples(wav: wav)
        progress("определяю говорящих…")
        let result = try await Task.detached(priority: .userInitiated) {
            try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        }.value

        // speakerId → «Спикер N» в порядке первого появления
        var order: [String: Int] = [:]
        return result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { segment in
                if order[segment.speakerId] == nil {
                    order[segment.speakerId] = order.count + 1
                }
                return SpeakerSegment(
                    speaker: "Спикер \(order[segment.speakerId]!)",
                    start: Double(segment.startTimeSeconds),
                    end: Double(segment.endTimeSeconds))
            }
    }

    private func prepared(progress: @escaping @Sendable (String) -> Void) async throws -> DiarizerManager {
        if let manager { return manager }
        progress("модели диаризации…")
        let models = try await DiarizerModels.downloadIfNeeded()
        let created = DiarizerManager()
        created.initialize(models: models)
        manager = created
        return created
    }

    private func loadSamples(wav: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: wav)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: 1,
            interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw MeetRecError("Не удалось прочитать аудио для диаризации.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw MeetRecError("Пустой аудиобуфер.")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
