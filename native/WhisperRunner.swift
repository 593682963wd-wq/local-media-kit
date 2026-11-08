import Foundation

/// Wraps whisper.cpp's `whisper-cli` binary. Requires caller-supplied binary and model paths; no downloader is included.
final class WhisperRunner {
    // One writer per capture; result() waits for that writer before reading.
    private final class PipeCapture: @unchecked Sendable {
        let pipe = Pipe()
        private let finished = DispatchGroup()
        private var data = Data()

        func start() {
            try? pipe.fileHandleForWriting.close()
            finished.enter()
            DispatchQueue.global(qos: .utility).async {
                self.data = self.pipe.fileHandleForReading.readDataToEndOfFile()
                try? self.pipe.fileHandleForReading.close()
                self.finished.leave()
            }
        }

        func result() -> Data {
            finished.wait()
            return data
        }
    }

    enum RunError: LocalizedError {
        case binaryMissing(URL)
        case modelMissing(URL)
        case nonZeroExit(Int32, String)
        case noOutput
        var errorDescription: String? {
            switch self {
            case .binaryMissing(let u): return "找不到 whisper-cli：\(u.path)\n请提供调用者自备的可执行文件"
            case .modelMissing(let u):  return "找不到模型文件：\(u.path)\n请提供调用者自备且有权使用的模型"
            case .nonZeroExit(let c, let msg): return "whisper 退出码 \(c)：\(msg)"
            case .noOutput: return "whisper 没有输出文本"
            }
        }
    }

    func transcribe(wavURL: URL, language: String, modelPath: URL, binaryURL: URL) -> Result<String, Error> {
        let binary = binaryURL
        guard FileManager.default.fileExists(atPath: binary.path) else {
            return .failure(RunError.binaryMissing(binary))
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            return .failure(RunError.modelMissing(modelPath))
        }

        let workDirectory: URL
        do {
            workDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: FileManager.default.temporaryDirectory,
                create: true)
        } catch {
            return .failure(error)
        }
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let outBase = workDirectory.appendingPathComponent("transcript")
        let process = Process()
        process.executableURL = binary
        var args = [
            "-m", modelPath.path,
            "-f", wavURL.path,
            "-otxt",
            "-of", outBase.path,
            // 用全部物理核（M 系列上 whisper.cpp Metal 后端 + 高线程数收益最大）
            "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount))",
            "-p", "1",
            // 贪婪解码：beam=1 / best-of=1，比默认 5 快 ~3-4×，短语音质量几乎无损
            "-bs", "1",
            "-bo", "1",
            // 不保留上文 token，避免上一段污染本段、也少做计算
            "-mc", "0",
            "--no-timestamps"
            // NOTE: Do NOT pass --prompt here. whisper.cpp will literally echo
            // the prompt back as the transcription when the audio is short or
            // silent, which produced bogus results like "以下是普通话简体中文的句子".
        ]
        if language != "auto" {
            args += ["-l", language]
        } else {
            args += ["-l", "auto"]
        }
        process.arguments = args

        let stderrCapture = PipeCapture()
        let stdoutCapture = PipeCapture()
        process.standardError = stderrCapture.pipe
        process.standardOutput = stdoutCapture.pipe

        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        stderrCapture.start()
        stdoutCapture.start()
        process.waitUntilExit()
        let stderrData = stderrCapture.result()
        let stdoutData = stdoutCapture.result()

        if process.terminationStatus != 0 {
            let msg = String(data: stderrData, encoding: .utf8) ?? ""
            return .failure(RunError.nonZeroExit(process.terminationStatus, msg))
        }

        let txtURL = outBase.appendingPathExtension("txt")
        if let text = try? String(contentsOf: txtURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: txtURL)
            return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Fallback: parse stdout
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let cleaned = stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("whisper_") }
            .joined(separator: " ")
        return cleaned.isEmpty ? .failure(RunError.noOutput) : .success(cleaned)
    }
}
