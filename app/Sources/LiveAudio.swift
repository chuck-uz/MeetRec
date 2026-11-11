// Звук для живых субтитров: буферы ScreenCaptureKit → 16 кГц моно, нарезка окон
// по паузам, поиск эха звонка в микрофоне. Логика перенесена из meetvoice-kit (audio.py).
import Accelerate
import CoreMedia
import Foundation

/// Частота, с которой работает Whisper.
let liveSampleRate = 16_000

/// Принимает аудиобуферы одной дорожки (на очереди захвата) и копит 16 кГц моно,
/// которые рабочий поток субтитров забирает через `drain()`.
final class LiveTrackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var resampler: LinearResampler?

    func push(_ sampleBuffer: CMSampleBuffer) {
        guard let (mono, rate) = Self.monoSamples(sampleBuffer), !mono.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if resampler?.inputRate != rate {
            resampler = LinearResampler(inputRate: rate, outputRate: Double(liveSampleRate))
        }
        pending += resampler!.process(mono)
    }

    /// Готовые моно-сэмплы (режим проверки по файлу).
    func push(samples: [Float], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        if resampler?.inputRate != rate {
            resampler = LinearResampler(inputRate: rate, outputRate: Double(liveSampleRate))
        }
        pending += resampler!.process(samples)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    /// Сэмплы буфера, сведённые в моно float32, и их частота.
    private static func monoSamples(_ sampleBuffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let asbd = asbdPointer.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, asbd.mSampleRate > 0 else { return nil }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return nil }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channelsPerBuffer = nonInterleaved ? 1 : max(1, Int(asbd.mChannelsPerFrame))

        var mono = [Float](repeating: 0, count: frames)
        var sources = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (bits / 8) / channelsPerBuffer
            let count = min(frames, available)
            for channel in 0..<channelsPerBuffer {
                if isFloat {
                    let pointer = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<count { mono[i] += pointer[i * channelsPerBuffer + channel] }
                } else {
                    let pointer = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<count { mono[i] += Float(pointer[i * channelsPerBuffer + channel]) / 32768 }
                }
                sources += 1
            }
        }
        guard sources > 0 else { return nil }
        if sources > 1 {
            var scale = 1 / Float(sources)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        }
        return (mono, asbd.mSampleRate)
    }
}

/// Линейный ресемплер с состоянием между кусками (без щелчков на стыках).
struct LinearResampler {
    let inputRate: Double
    private let step: Double
    private var position: Double = 0 // в отсчётах входа относительно начала текущего куска
    private var previous: Float = 0

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        step = inputRate / outputRate
    }

    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        if step == 1 { return input }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        let last = input.count - 1
        while position <= Double(last) {
            let index = Int(position.rounded(.down))
            let fraction = Float(position - Double(index))
            let a = index < 0 ? previous : input[index]
            let b = index + 1 <= last ? input[index + 1] : a
            out.append(a + (b - a) * fraction)
            position += step
        }
        position -= Double(input.count)
        previous = input[last]
        return out
    }
}

/// Обработка 16 кГц моно: громкость, нарезка по паузам, речь, эхо звонка.
enum LiveDSP {
    static let rate = Double(liveSampleRate)

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var out: Float = 0
        samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &out, vDSP_Length($0.count)) }
        return out
    }

    /// Где резать окно: самые тихие 100 мс после `minCutSec`, чтобы не разрезать слово.
    static func quietCut(_ samples: ArraySlice<Float>, minCutSec: Double) -> Int {
        let frame = liveSampleRate / 10
        let base = samples.startIndex
        let count = samples.count
        let start = min(Int(minCutSec * rate), max(0, count - frame))
        var best = count
        var bestRMS = Float.infinity
        var i = start
        while i + frame <= count {
            let value = rms(samples[(base + i)..<(base + i + frame)])
            if value < bestRMS {
                bestRMS = value
                best = i + frame / 2
            }
            i += frame / 2
        }
        return best
    }

    /// Участки речи относительно собственного шума дорожки (энергетический VAD).
    static func speechRegions(
        _ audio: [Float], frameSec: Double = 0.03, gapSec: Double = 0.8,
        minSec: Double = 0.25, padSec: Double = 0.4
    ) -> [(Double, Double)] {
        let n = Int(rate * frameSec)
        let frames = audio.count / n
        guard frames > 0 else { return [] }
        var db = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            let value = Double(rms(audio[(f * n)..<((f + 1) * n)]))
            db[f] = 20 * log10(value + 1e-6)
        }
        let threshold = max(percentile(db, 0.10) + 12, -50)
        var raw: [(Double, Double)] = []
        for f in 0..<frames where db[f] > threshold {
            let t = Double(f) * frameSec
            if let last = raw.last, t - last.1 <= gapSec {
                raw[raw.count - 1].1 = t + frameSec
            } else {
                raw.append((t, t + frameSec))
            }
        }
        let total = Double(frames) * frameSec
        var out: [(Double, Double)] = []
        for (a0, b0) in raw where b0 - a0 >= minSec {
            let a = max(a0 - padSec, 0)
            let b = min(b0 + padSec, total)
            if let last = out.last, a <= last.1 {
                out[out.count - 1].1 = b
            } else {
                out.append((a, b))
            }
        }
        return out
    }

    // MARK: Эхо звонка в микрофоне (звук из динамиков вместо наушников)

    /// Огибающая: логарифм энергии по 10 мс, без среднего.
    static func logEnvelope(_ audio: [Float], hop: Int = 160) -> [Double] {
        let frames = audio.count / hop
        guard frames > 0 else { return [] }
        var env = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            audio.withUnsafeBufferPointer {
                vDSP_svesq($0.baseAddress! + f * hop, 1, &sum, vDSP_Length(hop))
            }
            env[f] = log(Double(sum) + 1e-9)
        }
        let mean = env.reduce(0, +) / Double(frames)
        return env.map { $0 - mean }
    }

    static func correlation(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let ma = a.prefix(n).reduce(0, +) / Double(n)
        let mb = b.prefix(n).reduce(0, +) / Double(n)
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a.prefix(n), b.prefix(n)) {
            let dx = x - ma, dy = y - mb
            dot += dx * dy
            na += dx * dx
            nb += dy * dy
        }
        let den = (na * nb).squareRoot()
        return den > 0 ? dot / den : 0
    }

    /// Сдвиг (в кадрах по 10 мс), с которым звук звонка слышен в микрофоне.
    /// nil — дорожки не связаны (наушники).
    static func crosstalkLag(
        mic: [Float], ref: [Float], maxLagSec: Double = 1, minCorr: Double = 0.15, minSec: Double
    ) -> Int? {
        let em = logEnvelope(mic), er = logEnvelope(ref)
        let n = min(em.count, er.count)
        guard Double(n) >= minSec * 100 else { return nil }
        let normM = em.prefix(n).reduce(0) { $0 + $1 * $1 }.squareRoot()
        let normR = er.prefix(n).reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard normM > 0, normR > 0 else { return nil }
        let k = Int(maxLagSec * 100)
        var bestLag = 0
        var bestValue = -Double.infinity
        for lag in -k...k {
            // c[lag] = Σ em[t + lag] · er[t]
            var sum = 0.0
            let from = max(0, -lag), to = min(n, n - lag)
            if from < to {
                for t in from..<to { sum += em[t + lag] * er[t] }
            }
            let value = sum / (normM * normR)
            if value > bestValue {
                bestValue = value
                bestLag = lag
            }
        }
        return bestValue >= minCorr ? bestLag : nil
    }

    /// Убирает из участков речи микрофона куски, чья огибающая повторяет звонок.
    /// Когда пользователь говорит поверх звонка, огибающие расходятся — такие куски остаются.
    static func dropCrosstalk(
        regions: [(Double, Double)], mic: [Float], ref: [Float], lag: Int,
        winSec: Double = 2, threshold: Double = 0.45
    ) -> [(Double, Double)] {
        let em = logEnvelope(mic), er = logEnvelope(ref)
        let step = Int(winSec * 100)
        var out: [(Double, Double)] = []
        for (a, b) in regions {
            var t = Int(a * 100)
            let end = Int(b * 100)
            var keepFrom: Int?
            while t < end {
                let u = min(t + step, end)
                let s0 = t - lag, s1 = u - lag
                var other = false
                if s0 >= 0, s1 <= er.count, u <= em.count, u - t >= 30 {
                    other = correlation(em[t..<u], er[s0..<s1]) >= threshold
                }
                if !other, keepFrom == nil { keepFrom = t }
                if other, let from = keepFrom {
                    out.append((Double(from) / 100, Double(t) / 100))
                    keepFrom = nil
                }
                t = u
            }
            if let from = keepFrom { out.append((Double(from) / 100, b)) }
        }
        return out.filter { $0.1 - $0.0 >= 0.3 }
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    /// 16 кГц моно → WAV PCM16 (для whisper-cli).
    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(liveSampleRate))
        append(UInt32(liveSampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }
}
