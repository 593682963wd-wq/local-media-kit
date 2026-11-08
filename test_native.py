"""作者：Wangyuan；日期：2026-10-29；职责：纯文本/合成WAV原生验证，绝不打开麦克风。"""
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), '需要 macOS Swift 工具链')
class NativeComponentsTests(unittest.TestCase):
    def test_text_wave_and_explicit_history(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            audio = root / 'synthetic.wav'
            with wave.open(str(audio), 'wb') as writer:
                writer.setnchannels(1)
                writer.setsampwidth(2)
                writer.setframerate(16000)
                writer.writeframes(bytes(32000))
            main = root / 'main.swift'
            main.write_text('''import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let audio=root.appendingPathComponent("synthetic.wav")
let cleaned=TextPostProcessor.stripFillers("um hello")
precondition(cleaned.contains("hello") && !cleaned.contains("um"))
let inspected=WavInspector.inspect(url:audio)
precondition(inspected.duration > 0.99 && inspected.duration < 1.01)
let history=HistoryStore(url:root.appendingPathComponent("history.json"))
history.append(text:"Synthetic",audioURL:audio,duration:1,language:"en")
precondition(history.entries.count == 1)
history.clear()
precondition(history.entries.isEmpty && FileManager.default.fileExists(atPath:audio.path))
print("native pure components passed")
''')
            sources = sorted((Path(__file__).parent / 'native').glob('*.swift'))
            build = subprocess.run(['swiftc', *map(str, sources), str(main), '-o', str(root / 'check')], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(root / 'check'), str(root)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('native pure components passed', result.stdout)
