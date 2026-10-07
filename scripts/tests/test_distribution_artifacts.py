"""Verify real built artifacts when dist/ exists; no network or credentials."""
import hashlib
import json
import tarfile
import unittest
from email.parser import BytesParser
from pathlib import Path
from zipfile import ZipFile
from vibemeeting import __version__ as VERSION

ROOT = Path(__file__).resolve().parents[2]
WHEEL = ROOT / f'dist/vibemeeting-{VERSION}-py3-none-any.whl'
SDIST = ROOT / f'dist/vibemeeting-{VERSION}.tar.gz'


@unittest.skipUnless(WHEEL.is_file() and SDIST.is_file(), 'Build wheel and sdist first to verify distribution artifacts.')
class DistributionArtifactTests(unittest.TestCase):
    def test_wheel_declares_console_entry_python_range_license_and_dependencies(self):
        with ZipFile(WHEEL) as archive:
            metadata = BytesParser().parsebytes(archive.read(f'vibemeeting-{VERSION}.dist-info/METADATA'))
            self.assertEqual(metadata['Name'], 'vibemeeting')
            self.assertEqual(metadata['Version'], VERSION)
            self.assertEqual(metadata['Requires-Python'], '<3.14,>=3.10')
            self.assertEqual(metadata['License-Expression'], 'Apache-2.0')
            self.assertIn('django==5.2.2', metadata.get_all('Requires-Dist'))
            entries = archive.read(f'vibemeeting-{VERSION}.dist-info/entry_points.txt').decode()
            self.assertIn('vibemeeting = vibemeeting.cli:main', entries)

    def test_wheel_has_complete_verified_application_and_no_runtime_data(self):
        with ZipFile(WHEEL) as archive:
            prefix = 'vibemeeting/_app/'
            manifest = json.loads(archive.read(prefix + 'bundle-manifest.json'))
            required = {'manage.py', 'scripts/launcher.py', 'conference/models.py',
                        'conference/migrations/0001_initial.py', 'smart_meeting/settings.py',
                        'app/templates/registration/login.html', 'app/static/style.css',
                        'app/static/brand/vibemeeting-logo.png',
                        'artifacts/flutter_app_web/index.html', 'artifacts/flutter_app_web/main.dart.js',
                        'compose.recording.yaml', 'LICENSE', 'NOTICE'}
            self.assertTrue(required <= set(manifest['files']))
            actual = {n[len(prefix):] for n in archive.namelist() if n.startswith(prefix)}
            self.assertEqual(actual, set(manifest['files']) | {'bundle-manifest.json'})
            for name, checksum in manifest['files'].items():
                self.assertEqual(hashlib.sha256(archive.read(prefix + name)).hexdigest(), checksum, name)
            for name in archive.namelist():
                parts = Path(name).parts
                self.assertFalse({'.runtime', '.git', '.venv', '.certs', 'tools', '__pycache__'} & set(parts), name)
                self.assertNotIn(Path(name).suffix, {'.db', '.key', '.pem', '.mp4', '.log', '.pyc'}, name)
                self.assertNotEqual(Path(name).name, '.env', name)

    def test_sdist_contains_prebuilt_application_equal_to_wheel(self):
        with tarfile.open(SDIST, 'r:gz') as archive, ZipFile(WHEEL) as wheel:
            prefix = f'vibemeeting-{VERSION}/vibemeeting/_app/'
            manifest = json.load(archive.extractfile(prefix + 'bundle-manifest.json'))
            wheel_manifest = json.loads(wheel.read('vibemeeting/_app/bundle-manifest.json'))
            self.assertEqual(manifest, wheel_manifest)
            for name, checksum in manifest['files'].items():
                self.assertEqual(hashlib.sha256(archive.extractfile(prefix + name).read()).hexdigest(), checksum, name)
            for member in archive.getmembers():
                self.assertFalse(member.issym() or member.islnk(), member.name)
                self.assertNotIn('.runtime', Path(member.name).parts)
                self.assertNotIn('.git', Path(member.name).parts)


if __name__ == '__main__':
    unittest.main()
