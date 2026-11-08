// 作者：Wangyuan；日期：2026-11-08。
import Foundation
import XCTest

// Compile as a separate test executable together with the four native source
// files under test. No application module name or project target is assumed.
@objc final class NativeRegressionTests: XCTestCase {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @objc func testTwo4096FrameBuffersAt48kHz() {
        let input = (0..<8192).map { Float($0) / 16384 }
        var streaming = PCM16Resampler()
        let first = streaming.process(Array(input[..<4096]), sourceRate: 48_000)
        let second = streaming.process(Array(input[4096...]), sourceRate: 48_000)
        XCTAssertEqual(first.count, 1365)
        XCTAssertEqual(second.count, 1366)
        XCTAssertEqual(first.first, Int16(0))
        XCTAssertEqual(first.last, Int16(8183))
        XCTAssertEqual(second.first, Int16(8189))
        XCTAssertEqual(second.last, Int16(16379))
        var uninterrupted = PCM16Resampler()
        XCTAssertEqual(first + second, uninterrupted.process(input, sourceRate: 48_000))
    }

    @objc func testFractionalInterpolationAcrossTinyBuffersAndReset() {
        var resampler = PCM16Resampler()
        var result = resampler.process([0, 0.5], sourceRate: 24_000)
        XCTAssertEqual(resampler.process([], sourceRate: 24_000), [])
        result += resampler.process([1], sourceRate: 24_000)
        result += resampler.process([-0.5, -1, 0.5], sourceRate: 24_000)
        XCTAssertEqual(result, [0, 24575, -16383, -8191])
        resampler.reset()
        XCTAssertEqual(resampler.process([-1, 1], sourceRate: 16_000), [-32767])
    }

    @objc func testSameSecondRecordingsAndExclusiveWAVCreation() throws {
        try withTemporaryDirectory { directory in
            let date = Date(timeIntervalSince1970: 1_000)
            let first = AudioRecorder.makeOutputURL(in: directory, at: date)
            let second = AudioRecorder.makeOutputURL(in: directory, at: date)
            XCTAssertNotEqual(first, second)
            try AudioRecorder.writeWAV(samples: [1234, -2345], sampleRate: 16_000, to: first)
            let original = try Data(contentsOf: first)
            try AudioRecorder.writeWAV(samples: [42], sampleRate: 16_000, to: second)
            XCTAssertThrowsError(try AudioRecorder.writeWAV(samples: [0], sampleRate: 16_000, to: first))
            XCTAssertEqual(try Data(contentsOf: first), original)
            let firstInfo = WavInspector.inspect(url: first)
            let secondInfo = WavInspector.inspect(url: second)
            XCTAssertEqual(firstInfo.peak, 2345)
            XCTAssertEqual(firstInfo.duration, 2.0 / 16_000, accuracy: 0.0000001)
            XCTAssertEqual(secondInfo.peak, 42)
            XCTAssertEqual(secondInfo.duration, 1.0 / 16_000, accuracy: 0.0000001)
        }
    }

    @objc func testRealBodyContainingFormerlyBannedPhraseSurvives() throws {
        try withTemporaryDirectory { directory in
            let dictionary = directory.appendingPathComponent("dictionary.json")
            let processor = TextPostProcessor(dictionaryURL: dictionary)
            XCTAssertEqual(processor.apply("今天讨论谢谢大家的观看这句话"), "今天讨论谢谢大家的观看这句话。")
            var options = ProcessingOptions()
            options.removeFillers = false
            options.removeRepetitions = false
            options.autoEdit = false
            options.autoFormat = false
            let disabled = TextPostProcessor(dictionaryURL: dictionary, options: options)
            XCTAssertEqual(disabled.apply("谢谢大家的观看"), "谢谢大家的观看")
            XCTAssertEqual(disabled.apply("thanks for watching this explanation"), "thanks for watching this explanation")
        }
    }

    @objc func testRepetitionCleanupIsOptInAndDictionaryStillApplies() throws {
        try withTemporaryDirectory { directory in
            let dictionary = directory.appendingPathComponent("dictionary.json")
            let processor = TextPostProcessor(dictionaryURL: dictionary)
            XCTAssertEqual(processor.apply("妈妈来了"), "妈妈来了。")
            processor.saveRules([TextPostProcessor.Rule(from: "术语甲", to: "术语乙", regex: false)])
            XCTAssertEqual(processor.apply("妈妈说术语甲"), "妈妈说术语乙。")
            var options = ProcessingOptions()
            options.removeRepetitions = true
            let enabled = TextPostProcessor(dictionaryURL: dictionary, options: options)
            XCTAssertEqual(enabled.apply("我我我想说"), "我想说。")
            XCTAssertEqual(enabled.apply("the the cat"), "The cat")
        }
    }

    private func fakeTranscription(in directory: URL, body: String) throws -> Result<String, Error> {
        let wav = directory.appendingPathComponent("a.wav")
        let model = directory.appendingPathComponent("fixture-model.bin")
        let binary = directory.appendingPathComponent("fixture-whisper")
        // These are inert placeholders; only the fake child reads arguments.
        try Data().write(to: wav)
        try Data().write(to: model)
        let script = """
        #!/bin/sh
        out=
        input=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -of) shift; out=$1 ;;
                -f) shift; input=$1 ;;
            esac
            shift
        done
        printf '%s' "$out" > "$input.prefix"
        \(body)
        """
        try script.write(to: binary, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return WhisperRunner().transcribe(wavURL: wav, language: "auto", modelPath: model, binaryURL: binary)
    }

    private func assertWorkspaceRemoved(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = directory.appendingPathComponent("a.wav.prefix")
        let prefix = try String(contentsOf: marker, encoding: .utf8)
        let workspace = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        XCTAssertNotEqual(workspace.standardizedFileURL, directory.standardizedFileURL, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), file: file, line: line)
    }

    @objc func testWhisperOwnOutputDoesNotReplaceSiblingText() throws {
        try withTemporaryDirectory { directory in
            let sibling = directory.appendingPathComponent("a.txt")
            try "keep original".write(to: sibling, atomically: false, encoding: .utf8)
            let result = try fakeTranscription(in: directory, body: "printf ' fresh transcript \\n' > \"$out.txt\"\nexit 0")
            XCTAssertEqual(try result.get(), "fresh transcript")
            XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep original")
            try assertWorkspaceRemoved(in: directory)
        }
    }

    @objc func testWhisperMissingOutputCannotReuseOldSiblingAndCanRecover() throws {
        try withTemporaryDirectory { directory in
            let sibling = directory.appendingPathComponent("a.txt")
            try "keep original".write(to: sibling, atomically: false, encoding: .utf8)
            let result = try fakeTranscription(in: directory, body: "exit 0")
            if case .failure(let error) = result,
               let runError = error as? WhisperRunner.RunError,
               case .noOutput = runError {
                // Expected: the unrelated sibling is not transcription output.
            } else {
                XCTFail("Expected noOutput, got \(result)")
            }
            XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep original")
            try assertWorkspaceRemoved(in: directory)
            let recovered = try fakeTranscription(in: directory, body: "printf 'recovered\\n'\nexit 0")
            XCTAssertEqual(try recovered.get(), "recovered")
            try assertWorkspaceRemoved(in: directory)
        }
    }

    private func floodScript(exitStatus: Int) -> String {
        // The watchdog bounds the regression case where waitUntilExit blocks
        // while the child is stuck writing a full pipe. It has no pipe handles.
        """
        (sleep 10; kill -TERM "$$" 2>/dev/null) >/dev/null 2>&1 &
        watchdog=$!
        trap 'exit 124' TERM
        chunk=$(printf '%01024d' 0)
        i=0
        while [ "$i" -lt 256 ]; do
            printf '[%s]\\n' "$chunk"
            printf '%s\\n' "$chunk" >&2
            i=$((i + 1))
        done
        kill "$watchdog" 2>/dev/null || :
        wait "$watchdog" 2>/dev/null || :
        printf 'fallback transcript\\n'
        exit \(exitStatus)
        """
    }

    @objc func testBothWhisperPipesAreDrainedForSuccessAndFailure() throws {
        for status in [0, 7] {
            try withTemporaryDirectory { directory in
                let result = try fakeTranscription(in: directory, body: floodScript(exitStatus: status))
                if status == 0 {
                    XCTAssertEqual(try result.get(), "fallback transcript")
                } else if case .failure(let error) = result,
                          let runError = error as? WhisperRunner.RunError,
                          case .nonZeroExit(let code, let message) = runError {
                    XCTAssertEqual(code, 7)
                    XCTAssertGreaterThanOrEqual(message.utf8.count, 256 * 1024)
                } else {
                    XCTFail("Expected nonZeroExit, got \(result)")
                }
                try assertWorkspaceRemoved(in: directory)
            }
        }
    }

    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }

    private var monoFormat: [UInt8] {
        le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
    }

    private func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(UInt32(payload.count)) + payload + (payload.count % 2 == 1 ? [0] : [])
    }

    private func wave(_ chunks: [[UInt8]]) -> Data {
        let payload = Array("WAVE".utf8) + chunks.flatMap { $0 }
        return Data(Array("RIFF".utf8) + le32(UInt32(payload.count)) + payload)
    }

    @objc func testWAVOddJunkPaddingBeforeFormatAndData() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("silent.wav")
            let fixture = wave([
                chunk("JUNK", [0x7f]),
                chunk("fmt ", monoFormat),
                chunk("data", Array(repeating: 0, count: 32))
            ])
            try fixture.write(to: url)
            let result = WavInspector.inspect(url: url)
            XCTAssertEqual(result.peak, 0)
            XCTAssertEqual(result.duration, 0.001, accuracy: 0.0000001)
        }
    }

    @objc func testWAVMissingDataMissingFormatAndTruncationFailClosed() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("invalid.wav")
            let noData = wave([
                chunk("fmt ", monoFormat),
                chunk("JUNK", Array(repeating: 0x7f, count: 12))
            ])
            let noFormat = wave([chunk("data", Array(repeating: 0x7f, count: 40))])
            var truncated = wave([
                chunk("fmt ", monoFormat),
                chunk("data", Array(repeating: 0, count: 32))
            ])
            truncated.removeLast()
            for fixture in [noData, noFormat, truncated] {
                try fixture.write(to: url)
                let result = WavInspector.inspect(url: url)
                XCTAssertEqual(result.peak, 0)
                XCTAssertEqual(result.duration, 0)
            }
            let valid = wave([
                chunk("fmt ", monoFormat),
                chunk("data", le16(UInt16(bitPattern: -2000)) + le16(1000))
            ])
            try valid.write(to: url)
            let recovered = WavInspector.inspect(url: url)
            XCTAssertEqual(recovered.peak, 2000)
            XCTAssertEqual(recovered.duration, 2.0 / 16_000, accuracy: 0.0000001)
        }
    }
}

