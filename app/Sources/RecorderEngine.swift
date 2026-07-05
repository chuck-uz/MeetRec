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

struct RecordingResult {
    let audioURL: URL
    let videoURL: URL?
}

final class RecorderEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private var videoInput: AVAssetWriterInput?
    private let captureVideo: Bool
    private let sampleQueue = DispatchQueue(label: "meetrec.samples")
    private var sessionStarted = false
    private var stream: SCStream?
    let tempURL: URL
    let finalURL: URL
    let videoFinalURL: URL?
    var onInterrupted: ((Error) -> Void)?

    init(outputDir: URL, title: String? = nil, captureVideo: Bool = false) throws {
        self.captureVideo = captureVideo
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: Date())
        let baseName = title.map { "\($0) — \(stamp)" } ?? "Встреча \(stamp)"
        var url = outputDir.appendingPathComponent(baseName + ".m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputDir.appendingPathComponent("\(baseName) (\(counter)).m4a")
            counter += 1
        }
        finalURL = url
        videoFinalURL = captureVideo
            ? url.deletingPathExtension().appendingPathExtension("mp4")
            : nil
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

        if captureVideo {
            // Пиксельный размер дисплея, ограниченный 2560 по ширине.
            let scale = max(1, filter.pointPixelScale)
            var pixelWidth = Int(Float(display.width) * scale)
            var pixelHeight = Int(Float(display.height) * scale)
            if pixelWidth > 2560 {
                pixelHeight = pixelHeight * 2560 / pixelWidth
                pixelWidth = 2560
            }
            pixelWidth &= ~1
            pixelHeight &= ~1
            config.width = pixelWidth
            config.height = pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.queueDepth = 8

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            videoInput = input
        } else {
            // Видео не нужно, но поток обязан его отдавать — сводим к минимуму.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
        }

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

    /// Останавливает захват, сводит дорожки и возвращает пути к готовым файлам.
    func stop() async throws -> RecordingResult {
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
        videoInput?.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? MeetRecError("Ошибка при завершении записи файла.")
        }
        do {
            try await mixdown(from: tempURL, to: finalURL)
        } catch {
            // Если сведение не удалось — сохраняем «сырой» файл со всеми дорожками.
            let fallback = finalURL.deletingPathExtension().appendingPathExtension("mov")
            try FileManager.default.moveItem(at: tempURL, to: fallback)
            return RecordingResult(audioURL: fallback, videoURL: captureVideo ? fallback : nil)
        }

        var videoURL: URL?
        if let videoFinalURL {
            do {
                videoURL = try await remuxVideo(source: tempURL, mixedAudio: finalURL, to: videoFinalURL)
            } catch {
                // Ремукс не удался — оставляем «сырой» .mov, видео не теряется.
                let fallback = videoFinalURL.deletingPathExtension().appendingPathExtension("mov")
                if (try? FileManager.default.copyItem(at: tempURL, to: fallback)) != nil {
                    videoURL = fallback
                }
            }
        }
        try? FileManager.default.removeItem(at: tempURL)
        return RecordingResult(audioURL: finalURL, videoURL: videoURL)
    }

    /// Собирает итоговое видео: дорожка экрана без перекодирования + сведённый звук.
    /// Возвращает фактический путь (mp4, либо mov при несовместимости контейнера).
    @discardableResult
    private func remuxVideo(source: URL, mixedAudio: URL, to destination: URL) async throws -> URL {
        let sourceAsset = AVURLAsset(url: source)
        let audioAsset = AVURLAsset(url: mixedAudio)
        guard let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MeetRecError("Не найдены дорожки для сборки видео.")
        }
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MeetRecError("Не удалось создать композицию видео.")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        try compVideo.insertTimeRange(videoRange, of: videoTrack, at: videoRange.start)
        let audioRange = try await audioTrack.load(.timeRange)
        try compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MeetRecError("Не удалось создать сессию сборки видео.")
        }
        do {
            try await export.export(to: destination, as: .mp4)
            return destination
        } catch {
            // Некоторые комбинации дорожек passthrough не кладёт в mp4 — пробуем mov.
            guard let retry = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw error
            }
            let movDestination = destination.deletingPathExtension().appendingPathExtension("mov")
            try await retry.export(to: movDestination, as: .mov)
            return movDestination
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
        case .screen:
            guard let videoInput, sampleBuffer.imageBuffer != nil, isCompleteFrame(sampleBuffer) else { return }
            append(sampleBuffer, to: videoInput)
        default: break
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

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int else { return true }
        return status == SCFrameStatus.complete.rawValue
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }
}
