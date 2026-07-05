// Движок записи: системный звук + микрофон → один .m4a (ScreenCaptureKit)
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct MeetRecError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class RecorderEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private let sampleQueue = DispatchQueue(label: "meetrec.samples")
    private var sessionStarted = false
    private var stream: SCStream?
    let tempURL: URL
    let finalURL: URL
    var onInterrupted: ((Error) -> Void)?

    init(outputDir: URL) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let baseName = "Встреча \(formatter.string(from: Date()))"
        var url = outputDir.appendingPathComponent(baseName + ".m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputDir.appendingPathComponent("\(baseName) (\(counter)).m4a")
            counter += 1
        }
        finalURL = url
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetrec-\(UUID().uuidString).mov")

        writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        systemInput.expectsMediaDataInRealTime = true
        micInput.expectsMediaDataInRealTime = true
        writer.add(systemInput)
        writer.add(micInput)
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw MeetRecError("Не найден дисплей для захвата звука.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
        // Видео не нужно, но поток обязан его отдавать — сводим к минимуму.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        guard writer.startWriting() else {
            throw writer.error ?? MeetRecError("Не удалось начать запись файла.")
        }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Останавливает захват, сводит дорожки и возвращает путь к готовому файлу.
    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        sampleQueue.sync {} // дождаться уже поступивших буферов
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            throw MeetRecError("Не получено ни одного аудиосэмпла — файл не сохранён.")
        }
        systemInput.markAsFinished()
        micInput.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? MeetRecError("Ошибка при завершении записи файла.")
        }
        do {
            try await mixdown(from: tempURL, to: finalURL)
            try? FileManager.default.removeItem(at: tempURL)
            return finalURL
        } catch {
            // Если сведение не удалось — сохраняем «сырой» файл с двумя дорожками.
            let fallback = finalURL.deletingPathExtension().appendingPathExtension("mov")
            try FileManager.default.moveItem(at: tempURL, to: fallback)
            return fallback
        }
    }

    // Сведение двух дорожек (система + микрофон) в один .m4a
    private func mixdown(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetRecError("Не удалось создать сессию экспорта.")
        }
        try await export.export(to: destination, as: .m4a)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: append(sampleBuffer, to: systemInput)
        case .microphone: append(sampleBuffer, to: micInput)
        default: break // видеокадры игнорируем
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }
}
