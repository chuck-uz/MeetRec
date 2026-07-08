// Движок записи: системный звук + микрофон → один .m4a (ScreenCaptureKit).
// Видео экрана — опционально. Источник видео: весь экран/дисплей или окно.
// При захвате окна звук всё равно пишется ПОЛНЫМ (второй поток по дисплею),
// чтобы не терять звук встречи, если снимаем не то окно, что его проигрывает.
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

final class RecorderEngine: NSObject, SCStreamDelegate {
    /// Маршрутизатор буферов конкретного потока в общий обработчик.
    private final class Output: NSObject, SCStreamOutput {
        let handler: (CMSampleBuffer, SCStreamOutputType) -> Void
        init(_ handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) { self.handler = handler }
        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            handler(buffer, type)
        }
    }

    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private var videoInput: AVAssetWriterInput?
    private let captureVideo: Bool
    private let videoSource: VideoSource
    private let sampleQueue = DispatchQueue(label: "meetrec.samples")
    private var sessionStarted = false

    // Потоки: аудио (полный звук + микрофон) и, при захвате окна, отдельный видео-поток.
    private var audioStream: SCStream?
    private var videoStream: SCStream?
    private var audioOutput: Output?
    private var videoOutput: Output?
    private var videoFinished = false // видео-вход завершён (окно закрылось/стоп)

    // Пауза: сдвигаем метки сэмплов на суммарную длительность пауз, чтобы
    // вырезать простой и получить бесшовный таймлайн. Всё — на sampleQueue.
    private var paused = false
    private var accumulatedPause = CMTime.zero
    private var pauseStartPTS: CMTime?
    let tempURL: URL
    let finalURL: URL
    let videoFinalURL: URL?
    var onInterrupted: ((Error) -> Void)?

    init(outputDir: URL, title: String? = nil, captureVideo: Bool = false,
         videoSource: VideoSource = .wholeScreen) throws {
        self.captureVideo = captureVideo
        self.videoSource = videoSource
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
        guard let mainDisplay = content.displays.first else {
            throw MeetRecError("Не найден дисплей для захвата звука.")
        }

        // Разрешаем выбранный источник в актуальные объекты.
        var window: SCWindow?
        var audioDisplay = mainDisplay
        if captureVideo {
            switch videoSource {
            case .window(let id):
                window = content.windows.first { $0.windowID == id }
                if window == nil { Log.error("Выбранное окно не найдено — пишу весь экран.") }
            case .display(let id):
                audioDisplay = content.displays.first { $0.displayID == id } ?? mainDisplay
            }
        }

        let audioOutput = Output { [weak self] buffer, type in
            guard let self, buffer.isValid else { return }
            switch type {
            case .audio: self.append(buffer, to: self.systemInput)
            case .microphone: self.append(buffer, to: self.micInput)
            default: break // видео-заглушка аудио-потока — игнорируем
            }
        }
        let videoOutput = Output { [weak self] buffer, type in
            guard let self, type == .screen, buffer.isValid,
                  !self.videoFinished, let input = self.videoInput,
                  buffer.imageBuffer != nil, self.isCompleteFrame(buffer) else { return }
            self.append(buffer, to: input)
        }
        self.audioOutput = audioOutput
        self.videoOutput = videoOutput

        if captureVideo, let window {
            // Двойной поток: A — полный звук + микрофон, B — видео окна.
            let audioConfig = SCStreamConfiguration()
            configureAudio(audioConfig)
            configureDummyVideo(audioConfig)
            let audioFilter = SCContentFilter(display: audioDisplay, excludingWindows: [])
            let aStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
            try aStream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: sampleQueue)
            try aStream.addStreamOutput(audioOutput, type: .microphone, sampleHandlerQueue: sampleQueue)
            try aStream.addStreamOutput(audioOutput, type: .screen, sampleHandlerQueue: sampleQueue)

            let videoFilter = SCContentFilter(desktopIndependentWindow: window)
            let videoConfig = SCStreamConfiguration()
            videoConfig.capturesAudio = false
            configureVideo(videoConfig,
                           pointWidth: Int(window.frame.width),
                           pointHeight: Int(window.frame.height),
                           scale: max(1, videoFilter.pointPixelScale))
            let bStream = SCStream(filter: videoFilter, configuration: videoConfig, delegate: self)
            try bStream.addStreamOutput(videoOutput, type: .screen, sampleHandlerQueue: sampleQueue)

            audioStream = aStream
            videoStream = bStream
            guard writer.startWriting() else {
                throw writer.error ?? MeetRecError("Не удалось начать запись файла.")
            }
            try await aStream.startCapture()
            try await bStream.startCapture()
        } else {
            // Одиночный поток: весь экран/дисплей (звук + видео) либо только звук.
            let config = SCStreamConfiguration()
            configureAudio(config)
            let filter = SCContentFilter(display: audioDisplay, excludingWindows: [])
            if captureVideo {
                configureVideo(config,
                               pointWidth: audioDisplay.width,
                               pointHeight: audioDisplay.height,
                               scale: max(1, filter.pointPixelScale))
            } else {
                configureDummyVideo(config)
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(audioOutput, type: .microphone, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(videoOutput, type: .screen, sampleHandlerQueue: sampleQueue)

            audioStream = stream
            guard writer.startWriting() else {
                throw writer.error ?? MeetRecError("Не удалось начать запись файла.")
            }
            try await stream.startCapture()
        }
    }

    // MARK: - Конфигурация потоков

    private func configureAudio(_ config: SCStreamConfiguration) {
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
    }

    /// Минимальное «видео» для аудио-потока (поток обязан отдавать экран).
    private func configureDummyVideo(_ config: SCStreamConfiguration) {
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
    }

    /// Настраивает реальное видео и создаёт видео-вход писателя (кап 2560 по ширине).
    private func configureVideo(_ config: SCStreamConfiguration, pointWidth: Int, pointHeight: Int, scale: Float) {
        var pixelWidth = Int(Float(pointWidth) * scale)
        var pixelHeight = Int(Float(pointHeight) * scale)
        if pixelWidth > 2560 {
            pixelHeight = pixelHeight * 2560 / max(1, pixelWidth)
            pixelWidth = 2560
        }
        pixelWidth &= ~1
        pixelHeight &= ~1
        pixelWidth = max(2, pixelWidth)
        pixelHeight = max(2, pixelHeight)
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
    }

    func pause() {
        sampleQueue.async { self.paused = true }
    }

    func resume() {
        sampleQueue.async { self.paused = false }
    }

    /// Останавливает захват, сводит дорожки и возвращает пути к готовым файлам.
    func stop() async throws -> RecordingResult {
        if let audioStream { try? await audioStream.stopCapture() }
        if let videoStream { try? await videoStream.stopCapture() }
        audioStream = nil
        videoStream = nil
        sampleQueue.sync {} // дождаться уже поступивших буферов
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            throw MeetRecError("Не получено ни одного аудиосэмпла — файл не сохранён.")
        }
        systemInput.markAsFinished()
        micInput.markAsFinished()
        sampleQueue.sync {
            if !videoFinished {
                videoFinished = true
                videoInput?.markAsFinished()
            }
        }
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

    // MARK: - Приём буферов

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if paused {
            // Отбрасываем сэмпл, но запоминаем границу начала паузы.
            if pauseStartPTS == nil { pauseStartPTS = pts }
            return
        }
        // Первый сэмпл после возобновления — прибавляем длительность паузы к смещению.
        if let start = pauseStartPTS {
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(pts, start))
            pauseStartPTS = nil
        }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts) // смещение здесь ещё нулевое
            sessionStarted = true
        }

        let toWrite: CMSampleBuffer
        if accumulatedPause == .zero {
            toWrite = sampleBuffer
        } else if let shifted = retimed(sampleBuffer, offset: accumulatedPause) {
            toWrite = shifted
        } else {
            return
        }
        if input.isReadyForMoreMediaData {
            input.append(toWrite)
        }
    }

    /// Копия сэмпла со сдвигом всех временных меток назад на `offset`.
    private func retimed(_ buffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int else { return true }
        return status == SCFrameStatus.complete.rawValue
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stream === videoStream {
            // Видео-поток умер (например, окно закрыли) — не роняем запись,
            // завершаем только видео, аудио продолжаем писать.
            sampleQueue.async {
                guard !self.videoFinished else { return }
                self.videoFinished = true
                self.videoInput?.markAsFinished()
            }
            Log.error("Видео-поток остановлен (окно закрыто?): \(error.localizedDescription). Аудио продолжается.")
        } else {
            onInterrupted?(error)
        }
    }
}
