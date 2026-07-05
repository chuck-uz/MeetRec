// meetrec — запись звука встреч на macOS (системный звук + микрофон → один .m4a)
// Сборка: swiftc -O -parse-as-library MeetRec.swift -o meetrec

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private let sampleQueue = DispatchQueue(label: "meetrec.samples")
    private var sessionStarted = false
    private var stream: SCStream?
    var onStreamStopped: ((Error) -> Void)?

    init(tempURL: URL) throws {
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
        onStreamStopped?(error)
    }

    func finish() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        sampleQueue.sync {} // дождаться уже поступивших буферов
        guard sessionStarted else {
            writer.cancelWriting()
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
    }
}

struct MeetRecError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Сведение двух дорожек (система + микрофон) в один .m4a
func mixdown(from source: URL, to destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw MeetRecError("Не удалось создать сессию экспорта.")
    }
    try await export.export(to: destination, as: .m4a)
}

func defaultOutputDir() -> URL {
    let fm = FileManager.default
    if let custom = ProcessInfo.processInfo.environment["MEETREC_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }
    // Если установлен Google Drive для рабочего стола — пишем сразу туда.
    let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    if let entries = try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.hasPrefix("GoogleDrive-") {
            for driveName in ["My Drive", "Мой диск"] {
                let drive = entry.appendingPathComponent(driveName)
                if fm.fileExists(atPath: drive.path) {
                    return drive.appendingPathComponent("Записи встреч")
                }
            }
        }
    }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Записи встреч")
}

@main
struct MeetRec {
    static var signalSources: [DispatchSourceSignal] = []

    static func main() async {
        let args = CommandLine.arguments
        let outDir: URL
        if args.count > 1 {
            outDir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            outDir = defaultOutputDir()
        }

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            fail("Не удалось создать папку \(outDir.path): \(error.localizedDescription)")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let baseName = "Встреча \(formatter.string(from: Date()))"
        var finalURL = outDir.appendingPathComponent(baseName + ".m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = outDir.appendingPathComponent("\(baseName) (\(counter)).m4a")
            counter += 1
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetrec-\(UUID().uuidString).mov")

        let recorder: Recorder
        do {
            recorder = try Recorder(tempURL: tempURL)
            try await recorder.start()
        } catch {
            fail("""
            Не удалось начать запись: \(error.localizedDescription)

            Скорее всего, не выдано разрешение. Откройте:
            Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука
            и включите приложение, из которого запускаете запись (Terminal / Claude).
            Там же в разделе «Микрофон» разрешите доступ к микрофону. После этого запустите снова.
            """)
        }

        print("🔴 Идёт запись (системный звук + микрофон)...")
        print("   Файл: \(finalURL.path)")
        print("   Для остановки нажмите Enter или Ctrl+C.")

        await waitForStop(recorder: recorder)

        print("\n⏳ Сохраняю запись...")
        do {
            try await recorder.finish()
            try await mixdown(from: tempURL, to: finalURL)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            // Если сведение не удалось — сохраняем «сырой» файл с двумя дорожками.
            let fallback = finalURL.deletingPathExtension().appendingPathExtension("mov")
            if FileManager.default.fileExists(atPath: tempURL.path),
               (try? FileManager.default.moveItem(at: tempURL, to: fallback)) != nil {
                print("⚠️  Сведение дорожек не удалось (\(error.localizedDescription)).")
                print("✅ Запись сохранена как: \(fallback.path)")
                exit(0)
            }
            fail("Ошибка при сохранении: \(error.localizedDescription)")
        }
        print("✅ Готово: \(finalURL.path)")
        exit(0)
    }

    static func waitForStop(recorder: Recorder) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let stopQueue = DispatchQueue(label: "meetrec.stop")
            var resumed = false
            let trigger: () -> Void = {
                stopQueue.async {
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                }
            }

            recorder.onStreamStopped = { error in
                FileHandle.standardError.write(
                    "\n⚠️  Захват прервался: \(error.localizedDescription)\n".data(using: .utf8)!)
                trigger()
            }

            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: stopQueue)
                source.setEventHandler {
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                }
                source.resume()
                signalSources.append(source)
            }

            if isatty(0) != 0 {
                Thread.detachNewThread {
                    _ = readLine()
                    trigger()
                }
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(("Ошибка: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }
}
