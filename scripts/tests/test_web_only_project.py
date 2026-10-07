"""Guard the web-only application boundary after retiring native clients."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'flutter_app'


class WebOnlyProjectTests(unittest.TestCase):
    def test_retired_frontend_directories_are_removed(self):
        for directory in ('flutter_dashboard', 'app/static/flutter_app'):
            with self.subTest(directory=directory):
                self.assertFalse((ROOT / directory).exists())

    def test_native_entrypoints_platforms_and_build_scripts_are_removed(self):
        retired = (
            'flutter_app/lib/main_windows.dart',
            'flutter_app/lib/windows_launcher',
            'flutter_app/windows', 'flutter_app/android', 'flutter_app/ios',
            'flutter_app/macos', 'flutter_app/linux',
            'scripts/build_flutter_windows.ps1',
            'scripts/build_flutter_android.ps1',
            'scripts/build_flutter_android.psm1',
            'scripts/tests/build_flutter_android.Tests.ps1',
            'docs/run/flutter-windows-launcher.md',
            'docs/run/remote-desktop-control.md',
        )
        remaining = [name for name in retired if (ROOT / name).exists()]
        self.assertEqual(remaining, [])
        self.assertTrue((APP / 'lib/main.dart').is_file())
        self.assertTrue((APP / 'web/index.html').is_file())

    def test_web_does_not_reference_retired_clients_or_remote_control(self):
        pattern = re.compile(r'windows_launcher|main_windows|remote_control|RemoteControl|remoteControl')
        matches = [str(path.relative_to(ROOT)) for path in (APP / 'lib').rglob('*.dart')
                   if pattern.search(path.read_text(encoding='utf-8'))]
        self.assertEqual(matches, [])

    def test_windows_ffi_is_not_a_direct_app_dependency(self):
        pubspec = (APP / 'pubspec.yaml').read_text(encoding='utf-8')
        self.assertNotRegex(pubspec, r'(?m)^  (win32|webview_windows):')

    def test_project_metadata_declares_only_web(self):
        metadata = (APP / '.metadata').read_text(encoding='utf-8')
        self.assertEqual(re.findall(r'platform: (\w+)', metadata), ['root', 'web'])
        self.assertNotIn('ios/Runner', metadata)

    def test_docs_and_tests_have_no_dangling_native_references(self):
        paths = list((APP / 'test').glob('*.dart')) + list((ROOT / 'docs').rglob('*.md'))
        paths += [ROOT / 'README.md', APP / 'README.md']
        pattern = re.compile(r'windows_launcher|main_windows|build_flutter_(windows|android)|flutter-windows-launcher|remote-desktop-control')
        matches = [str(path.relative_to(ROOT)) for path in paths
                   if path.exists() and pattern.search(path.read_text(encoding='utf-8'))]
        self.assertEqual(matches, [])


if __name__ == '__main__':
    unittest.main()
