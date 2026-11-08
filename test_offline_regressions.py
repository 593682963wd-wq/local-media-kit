# 作者：Wangyuan；日期：2026-11-08。
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np

from progress import _elapsed_minutes
from voice_energy import _energy_timestamps


ROOT = Path(__file__).resolve().parent


class ProgressRegressionTests(unittest.TestCase):
    def test_local_aware_time_uses_matching_timezone(self):
        now = datetime.fromisoformat('2026-10-29T10:05:00+08:00')
        self.assertEqual(_elapsed_minutes('10:00:00', now), 5.0)

    def test_naive_time_does_not_mix_timezone_kinds(self):
        now = datetime(2026, 10, 29, 10, 5)
        self.assertEqual(_elapsed_minutes('10:00:00', now), 5.0)

    def test_midnight_rollover_for_aware_and_naive_times(self):
        for tz in (None, timezone.utc, timezone(timedelta(hours=8))):
            with self.subTest(timezone=tz):
                now = datetime(2026, 10, 30, 0, 5, tzinfo=tz)
                self.assertEqual(_elapsed_minutes('23:55:00', now), 10.0)

    def test_invalid_timestamp_and_rounding(self):
        now = datetime(2026, 10, 29, 10, 5, 30, tzinfo=timezone.utc)
        self.assertIsNone(_elapsed_minutes('not a timestamp', now))
        self.assertEqual(_elapsed_minutes('10:00:00', now), 5.5)


class EnergyRegressionTests(unittest.TestCase):
    def test_short_active_clip_is_detected_to_its_actual_end(self):
        audio = np.full(511, 0.5, dtype=np.float32)
        self.assertEqual(_energy_timestamps(audio, 0.1), [(0.0, 511 / 16000)])

    def test_activity_only_in_partial_tail_is_detected(self):
        audio = np.concatenate((np.zeros(512), np.full(511, 0.5)))
        self.assertEqual(
            _energy_timestamps(audio, 0.1),
            [(512 / 16000, 1023 / 16000)],
        )

    def test_partial_frame_uses_actual_length_not_zero_padding(self):
        audio = np.concatenate((np.zeros(512), np.array([0.5])))
        self.assertEqual(
            _energy_timestamps(audio, 0.4),
            [(512 / 16000, 513 / 16000)],
        )

    def test_adjacent_full_and_partial_frames_merge_without_overrun(self):
        audio = np.full(600, 0.5)
        self.assertEqual(_energy_timestamps(audio, 0.1), [(0.0, 600 / 16000)])

    def test_silent_tail_closes_activity_at_full_frame_boundary(self):
        audio = np.concatenate((np.full(512, 0.5), np.zeros(11)))
        self.assertEqual(_energy_timestamps(audio, 0.1), [(0.0, 512 / 16000)])

    def test_empty_silent_and_threshold_equal_inputs(self):
        for audio in (np.array([], dtype=np.float32), np.zeros(17), np.full(511, 0.5)):
            with self.subTest(length=len(audio)):
                self.assertEqual(_energy_timestamps(audio, 0.5), [])


class CLIRegressionTests(unittest.TestCase):
    def load_cli(self, run_mock):
        # core.py was not supplied. Replace only that boundary while loading
        # the real CLI, without importing or guessing its dependencies.
        core_stub = types.ModuleType('core')
        core_stub.run = run_mock
        spec = importlib.util.spec_from_file_location(
            '_offline_cli_regression', ROOT / 'cli.py'
        )
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'core': core_stub}):
            spec.loader.exec_module(module)
        return module

    def invoke(self, module, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        code = 0
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                module.main()
            except SystemExit as exc:
                code = exc.code
        return code, stdout.getvalue(), stderr.getvalue()

    def test_media_errors_exit_two_and_later_invocation_can_succeed(self):
        failures = [
            RuntimeError('ffmpeg failed'),
            subprocess.TimeoutExpired(['ffmpeg', '-i', 'fixture.wav'], 1),
            subprocess.CalledProcessError(7, ['ffmpeg']),
        ]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'input.json'
            source.write_text('{}', encoding='utf-8')
            for failure in failures:
                with self.subTest(error=type(failure).__name__):
                    run_mock = Mock(side_effect=failure)
                    module = self.load_cli(run_mock)
                    code, stdout, stderr = self.invoke(module, ['cli.py', str(source)])
                    self.assertEqual(code, 2)
                    self.assertEqual(stdout, '')
                    self.assertIn(type(failure).__name__ + ':', stderr)
                    self.assertNotIn('Traceback', stderr)
                    run_mock.assert_called_once_with({})

                    run_mock.side_effect = None
                    run_mock.return_value = {'status': 'ok'}
                    code, stdout, stderr = self.invoke(module, ['cli.py', str(source)])
                    self.assertEqual(code, 0)
                    self.assertEqual(json.loads(stdout), {'status': 'ok'})
                    self.assertEqual(stderr, '')

    def test_existing_output_is_still_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'input.json'
            target = Path(directory) / 'output.json'
            source.write_text('{}', encoding='utf-8')
            target.write_text('keep me', encoding='utf-8')
            module = self.load_cli(Mock(return_value={'status': 'ok'}))
            code, stdout, stderr = self.invoke(
                module, ['cli.py', str(source), '--output', str(target)]
            )
            self.assertEqual(code, 2)
            self.assertEqual(stdout, '')
            self.assertIn('FileExistsError:', stderr)
            self.assertEqual(target.read_text(encoding='utf-8'), 'keep me')


if __name__ == '__main__':
    unittest.main()
