import Foundation

/// Reads back a 16-bit PCM WAV and returns (peakAbsSample, durationSeconds).
/// Used as a sanity check that the recorder actually wrote real audio (not a
/// silent file from a broken format converter).
enum WavInspector {
    static func inspect(url: URL) -> (peak: Int, duration: Double) {
        guard let data = try? Data(contentsOf: url), data.count >= 12,
              String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else { return (0, 0) }
        // Decode bytes explicitly: chunk headers need not be UInt32-aligned.
        func uint16LE(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func uint32LE(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        let riffEnd = Int(uint32LE(4)) + 8
        guard riffEnd >= 12, riffEnd <= data.count else { return (0, 0) }
        var idx = 12
        var dataOffset: Int?
        var dataSize = 0
        var sampleRate: UInt32?
        while idx + 8 <= riffEnd {
            let id = String(data: data.subdata(in: idx..<idx+4), encoding: .ascii) ?? ""
            let size = Int(uint32LE(idx + 4))
            let payload = idx + 8
            guard size <= riffEnd - payload else { return (0, 0) }
            if id == "fmt " {
                // The recorder writes mono, 16-bit integer PCM.
                guard size >= 16,
                      uint16LE(payload) == 1,
                      uint16LE(payload + 2) == 1,
                      uint16LE(payload + 12) == 2,
                      uint16LE(payload + 14) == 16,
                      uint32LE(payload + 4) > 0 else { return (0, 0) }
                sampleRate = uint32LE(payload + 4)
            } else if id == "data", dataOffset == nil {
                dataOffset = payload
                dataSize = size
            }
            let next = payload + size + size % 2
            guard next <= riffEnd else { return (0, 0) }
            idx = next
        }
        guard idx == riffEnd, let dataOffset, let sampleRate,
              dataSize > 0, dataSize % 2 == 0 else { return (0, 0) }
        var peak: Int16 = 0
        for offset in stride(from: dataOffset, to: dataOffset + dataSize, by: 2) {
            let value = Int16(bitPattern: uint16LE(offset))
            let magnitude = value == Int16.min ? Int16.max : abs(value)
            if magnitude > peak { peak = magnitude }
        }
        let duration = Double(dataSize / 2) / Double(sampleRate)
        return (Int(peak), duration)
    }
}

extension Data {
    /// Appends the data to a file at `url`, creating it if missing.
    func append(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: self)
            try h.close()
        } else {
            try write(to: url, options: .atomic)
        }
    }
}
