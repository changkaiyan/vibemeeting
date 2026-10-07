import argparse
import json
import tempfile
import unittest
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock, patch

from vibemeeting import cli
from scripts import launcher
from build_support import populate_bundle


class PipPackageTests(unittest.TestCase):
    def test_build_hook_loads_in_pep517_isolation_without_source_on_sys_path(self):
        source = Path(__file__).resolve().parents[2] / 'build_support.py'
        code = ('import importlib.util; '
                's=importlib.util.spec_from_file_location("build_support", ' + repr(str(source)) + '); '
                'm=importlib.util.module_from_spec(s); s.loader.exec_module(m)')
        result = subprocess.run([sys.executable, '-I', '-c', code], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_python_metadata_matches_current_django_supported_versions(self):
        metadata = (Path(__file__).resolve().parents[2] / 'pyproject.toml').read_text(encoding='utf-8')
        self.assertIn('requires-python = ">=3.10,<3.14"', metadata)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def bundle(self):
        bundle = self.root / 'bundle'
        bundle.mkdir()
        for name, content in [('manage.py', '# managed app'),
                              ('artifacts/flutter_app_web/index.html', 'compiled web')]:
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
        cli.write_manifest(bundle)
        return bundle

    def test_installs_bundled_app_and_preserves_data_on_upgrade(self):
        bundle, home = self.bundle(), self.root / 'home'
        cli.materialize(bundle, home)
        private = home / '.runtime/local.env'
        private.parent.mkdir()
        private.write_text('user configuration', encoding='utf-8')
        (bundle / 'manage.py').write_text('# upgraded', encoding='utf-8')
        cli.write_manifest(bundle)
        cli.materialize(bundle, home)
        self.assertEqual((home / 'manage.py').read_text(), '# upgraded')
        self.assertEqual(private.read_text(), 'user configuration')

    def test_refuses_to_overwrite_an_unmanaged_directory(self):
        bundle, home = self.bundle(), self.root / 'home'
        home.mkdir()
        (home / 'manage.py').write_text('user file', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'empty|managed'):
            cli.materialize(bundle, home)
        self.assertEqual((home / 'manage.py').read_text(), 'user file')

    def test_rejects_tampered_payload_before_changing_app(self):
        bundle, home = self.bundle(), self.root / 'home'
        (bundle / 'manage.py').write_text('tampered', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'checksum|integrity'):
            cli.materialize(bundle, home)
        self.assertFalse((home / 'manage.py').exists())

    def test_rejects_payload_paths_outside_managed_app(self):
        bundle = self.bundle()
        manifest = bundle / 'bundle-manifest.json'
        data = json.loads(manifest.read_text())
        data['files']['../private.txt'] = 'fake'
        manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            cli.materialize(bundle, self.root / 'home')

    def test_single_instance_lock_rejects_concurrent_launch(self):
        home = self.root / 'home'
        home.mkdir()
        with cli.instance_lock(home):
            with self.assertRaisesRegex(RuntimeError, 'already running'):
                with cli.instance_lock(home):
                    self.fail('Second launch acquired the same lock')
        with cli.instance_lock(home):
            pass

    def test_packaged_launch_uses_installed_python_and_bundled_web(self):
        index = self.root / 'artifacts/flutter_app_web/index.html'
        index.parent.mkdir(parents=True)
        index.write_text('compiled')
        args = argparse.Namespace(port=None, livekit_port=None, rtc_tcp_port=None,
                                  rtc_udp_port=None, turn_port=None, host_root=None,
                                  prepare_only=False, rebuild=False, packaged=True,
                                  project_name='vibemeeting-test')
        child = Mock()
        child.poll.return_value = None
        with patch.object(launcher, 'ROOT', self.root), patch.object(launcher, 'run') as run, \
             patch.object(launcher.shutil, 'which', return_value='docker'), \
             patch.object(launcher, 'check_ports'), patch.object(launcher, 'wait_http'), \
             patch.object(launcher, 'supervise'), patch.object(launcher, 'ensure_flutter') as flutter, \
             patch.object(launcher.subprocess, 'Popen', return_value=child) as popen:
            launcher.local(args)
        commands = [list(map(str, call.args[0])) for call in run.call_args_list]
        self.assertFalse(any('pip' in cmd or 'venv' in cmd for cmd in commands))
        flutter.assert_not_called()
        self.assertEqual(str(popen.call_args.args[0][0]), launcher.sys.executable)
        self.assertTrue(any('vibemeeting-test' in cmd and 'up' in cmd for cmd in commands))

    def test_prebuilt_sdist_bundle_can_build_without_flutter_or_repository(self):
        source = self.root / 'source'
        bundle = self.bundle()
        target = source / 'vibemeeting/_app'
        target.parent.mkdir(parents=True)
        import shutil
        shutil.copytree(bundle, target)
        output = self.root / 'output'
        populate_bundle(source, output)
        self.assertEqual((output / 'manage.py').read_text(), '# managed app')


if __name__ == '__main__':
    unittest.main()
