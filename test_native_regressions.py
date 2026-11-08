"""作者：Wangyuan；日期：2026-11-08。职责：执行不访问音频设备的原生回归。"""
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeOfflineRegressionTests(unittest.TestCase):
    def test_native_regression_executable(self):
        root = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix='media-native-tests-') as temporary:
            bundle = Path(temporary) / 'NativeRegressionTests.xctest'
            binary = bundle / 'Contents/MacOS/NativeRegressionTests'
            binary.parent.mkdir(parents=True)
            sources = ['AudioRecorder.swift', 'WhisperRunner.swift', 'TextPostProcessor.swift', 'WavInspector.swift']
            platform = subprocess.run(['xcrun', '--show-sdk-platform-path'], capture_output=True, text=True, timeout=15, check=True).stdout.strip()
            frameworks = str(Path(platform) / 'Developer/Library/Frameworks')
            swift_support = str(Path(platform) / 'Developer/usr/lib')
            build = subprocess.run(['swiftc', '-emit-library', '-I', swift_support, '-L', swift_support, '-lXCTestSwiftSupport', '-F', frameworks, '-framework', 'XCTest', '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', swift_support, *[str(root / 'native' / name) for name in sources], str(root / 'native_tests/NativeRegressionTests.swift'), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run(['xcrun', 'xctest', str(bundle)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Executed 10 tests', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
