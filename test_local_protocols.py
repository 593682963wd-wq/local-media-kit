"""作者：Wangyuan；日期：2026-11-08。职责：媒体入口拒绝URL及底层解码协议回归。"""
from pathlib import Path
import unittest
from unittest.mock import patch
import autoclip
from audio_validation import inspect_audio, AudioValidationError


class LocalProtocolTests(unittest.TestCase):
    def test_probe_rejects_url_before_spawning_child(self):
        with patch.object(autoclip.subprocess, 'run') as child:
            with self.assertRaisesRegex(ValueError, '本地'):
                autoclip.probe('http://127.0.0.1:9/synthetic.wav')
            child.assert_not_called()

    def test_ffprobe_positional_input_is_blocked_by_protocol_policy(self):
        result = autoclip.run([autoclip.FFPROBE, '-v', 'error', '-show_format', 'http://127.0.0.1:9/synthetic.wav'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not on whitelist', result.stderr)

    def test_cut_rejects_network_output_before_any_child(self):
        with patch.object(autoclip.subprocess, 'run') as child:
            with self.assertRaisesRegex(ValueError, '本地'):
                autoclip.cut_video('synthetic.mp4', 'http://127.0.0.1:9/output.wav', [[0,1]], False)
            child.assert_not_called()

    def test_audio_validator_rejects_url_before_libav_open(self):
        with patch('audio_validation.av.open') as decoder:
            with self.assertRaisesRegex(AudioValidationError, '本地'):
                inspect_audio('http://127.0.0.1:9/synthetic.wav', extension='.wav', max_minutes=1)
            decoder.assert_not_called()


if __name__ == '__main__':
    unittest.main()
