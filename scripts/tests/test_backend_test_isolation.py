"""Core backend regressions must run with only the declared web dependencies."""
import subprocess
import sys
import unittest
from pathlib import Path


class BackendTestIsolationTests(unittest.TestCase):
    def test_recording_suite_import_does_not_load_optional_stt_worker(self):
        code = '''
import importlib.abc
import os
import sys

class RejectOptionalWorker(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname.startswith('services.stt_worker'):
            raise ImportError('Core recording tests must not import the optional STT worker')

sys.meta_path.insert(0, RejectOptionalWorker())
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'smart_meeting.settings')
import django
django.setup()
from conference.tests import MeetingRecordingTests
assert MeetingRecordingTests.__name__ == 'MeetingRecordingTests'
'''
        result = subprocess.run(
            [sys.executable, '-c', code],
            cwd=Path(__file__).resolve().parents[2],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
