import Foundation
import AVFoundation

/// Streaming linear resampling without audio-device access.
struct PCM16Resampler {
    private var position: Double = 0
    private var previousSample: Float?

    mutating func reset() {
        position = 0
        previousSample = nil
    }

    mutating func process(_ samples: [Float], sourceRate: Double) -> [Int16] {
        guard !samples.isEmpty, sourceRate.isFinite, sourceRate > 0 else { return [] }
        var input = samples
        if let previousSample {
            input.insert(previousSample, at: 0)
        }
        let step = sourceRate / 16_000
        let lastPosition = Double(input.count - 1)
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 4)
        while position < lastPosition {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let sample = input[index] * (1 - fraction) + input[index + 1] * fraction
            let clipped = min(1, max(-1, sample))
            output.append(Int16(clipped * 32767))
            position += step
        }
        // The next buffer starts with this buffer's final sample. Position
        // therefore remains nonnegative, including when interpolation waits.
        position -= lastPosition
        previousSample = input.last
        return output
    }
}

/// Records the mic to a 16 kHz mono 16-bit PCM WAV file (whisper.cpp's expected format).
///
/// Implementation notes
/// --------------------
/// We deliberately avoid AVAudioConverter / AVAudioFile here. In practice
/// (especially after enabling Voice Processing IO), the format reported by
/// `inputNode.outputFormat(forBus:0)` does not always match the format of the
/// buffers actually delivered to the tap, which makes AVAudioConverter
/// silently emit zero-filled output. The user-visible symptom was a
/// "speaking" waveform on screen but a fully silent (-90 dBFS) WAV on disk,
/// which then made whisper.cpp hallucinate "你不要再想我了".
///
/// Instead we:
///   1. install the tap with `format: nil` so we receive the node's true
///      native float format,
///   2. accumulate Float32 samples in memory (after downmix + linear
///      resample to 16 kHz mono),
///   3. on stop, write a self-built 16-bit PCM WAV file.
final class AudioRecorder {
    private let outputDirectory: URL
    init(outputDirectory: URL) {self.outputDirectory=outputDirectory}
    private var engine: AVAudioEngine?
    private var outputURL: URL?
    private var pcm16: [Int16] = []
    private let pcmLock = NSLock()
    private var resampler = PCM16Resampler()
    private var sourceSampleRate: Double = 0
    private var sourceChannels: Int = 1

    /// Real-time level meter, 0...1 (RMS-ish). Updated on the audio tap thread.
    /// Subscribers should hop to main themselves.
    var onLevel: ((Float) -> Void)?

    /// Peak RMS observed during the current recording. Used by the caller to
    /// decide whether the clip is just silence (and therefore should NOT be
    /// sent to whisper, which would otherwise hallucinate canned phrases).
    private(set) var peakLevel: Float = 0
    private var softwareGain: Float = 1.0

    func start() throws {
        peakLevel = 0
        pcm16.removeAll(keepingCapacity: true)
        resampler.reset()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Try to enable Voice Processing IO (matches what macOS's own dictation
        // and IMEs use: AGC + noise suppression + echo cancellation). Falls
        // back to raw input + 4× software gain on devices/USB mics that don't
        // support VPIO.
        var voiceProcessingEnabled = false
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = true
        } catch {
            voiceProcessingEnabled = false
        }
        self.softwareGain = voiceProcessingEnabled ? 1.0 : 4.0

        // Read the node's true native format (post-VPIO).
        let nativeFormat = input.outputFormat(forBus: 0)
        self.sourceSampleRate = nativeFormat.sampleRate
        self.sourceChannels = Int(nativeFormat.channelCount)

        let url = Self.makeOutputURL(in: outputDirectory)
        self.outputURL = url

        // IMPORTANT: pass `format: nil` so AVAudioEngine gives us the node's
        // *actual* output format. Passing a stale `inputFormat` here was the
        // source of the silent-WAV bug — VPIO can change the reported format
        // under us and AVAudioConverter silently writes zeros.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.processBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // 1. Pull samples as Float32 (downmix to mono if needed).
        var mono = [Float](repeating: 0, count: frames)
        if let chPtr = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            if channels == 1 {
                let p = chPtr[0]
                for i in 0..<frames { mono[i] = p[i] }
            } else {
                let invC = 1.0 / Float(channels)
                for c in 0..<channels {
                    let p = chPtr[c]
                    for i in 0..<frames { mono[i] += p[i] * invC }
                }
            }
        } else if let int16Ptr = buffer.int16ChannelData {
            let channels = Int(buffer.format.channelCount)
            let invC = 1.0 / Float(channels)
            for c in 0..<channels {
                let p = int16Ptr[c]
                for i in 0..<frames { mono[i] += Float(p[i]) / 32768.0 * invC }
            }
        } else {
            return
        }

        // 2. Apply software gain (no-op when VPIO is on).
        let gain = self.softwareGain
        if gain != 1.0 {
            for i in 0..<frames {
                let v = mono[i] * gain
                mono[i] = v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v)
            }
        }

        // 3. Live level for the HUD (compute on raw mono, before resample).
        var sum: Float = 0
        for i in 0..<frames { sum += mono[i] * mono[i] }
        let rms = sqrtf(sum / Float(max(frames, 1)))
        let level = min(1, max(0, (log10f(max(rms, 1e-4)) + 4) / 4))
        if level > self.peakLevel { self.peakLevel = level }
        self.onLevel?(level)

        // 4. Linear-interpolate resample to 16 kHz, append as Int16.
        let out = self.resampler.process(mono, sourceRate: self.sourceSampleRate)

        self.pcmLock.lock()
        self.pcm16.append(contentsOf: out)
        self.pcmLock.unlock()
    }

    /// 启动时预热：先静默 start/stop 一次 AVAudioEngine，让 CoreAudio +
    /// VPIO 完成首次初始化（首次 ~150-300ms，预热后 ~5-15ms）。
    /// 必须在主线程调用一次（且必须在拿到麦克风权限后才有效果）。
    func prewarm() {
        let warmEngine = AVAudioEngine()
        let input = warmEngine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        // 装一个空的 tap 让 graph 跑通
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        warmEngine.prepare()
        do {
            try warmEngine.start()
            // 跑约 80ms 让 VPIO 实际就绪
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.08) {
                input.removeTap(onBus: 0)
                warmEngine.stop()
                try? input.setVoiceProcessingEnabled(false)
            }
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() throws -> URL {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Disable VPIO so the next AVAudioEngine instance starts clean.
        try? engine?.inputNode.setVoiceProcessingEnabled(false)
        engine = nil

        guard let url = outputURL else {
            throw NSError(domain: "Whisperboard", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "录音文件不存在"])
        }
        outputURL = nil

        pcmLock.lock()
        let samples = pcm16
        pcm16.removeAll(keepingCapacity: false)
        pcmLock.unlock()

        try Self.writeWAV(samples: samples, sampleRate: 16_000, to: url)
        return url
    }

    static func makeOutputURL(in dir: URL, at date: Date = Date()) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("rec-\(stamp)-\(UUID().uuidString).wav")
    }

    /// Write a minimal 16-bit PCM WAV header + data. Single channel.
    static func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        let byteRate = UInt32(sampleRate * 2)               // 1ch * 16bit/8
        let dataSize = UInt32(samples.count * 2)
        let chunkSize = 36 + dataSize

        var header = Data()
        func appendString(_ s: String) { header.append(contentsOf: s.utf8) }
        func appendUInt32LE(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { header.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { header.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32LE(chunkSize)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)                  // fmt chunk size
        appendUInt16LE(1)                   // PCM format
        appendUInt16LE(1)                   // mono
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(byteRate)
        appendUInt16LE(2)                   // block align: 1ch * 16bit/8
        appendUInt16LE(16)                  // bits per sample
        appendString("data")
        appendUInt32LE(dataSize)

        // Append PCM body.
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                header.append(Data(bytes: base, count: ptr.count * 2))
            }
        }
        try header.write(to: url, options: .withoutOverwriting)
    }
}
