"""Validate real Compose interpolation without starting containers or a daemon."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.launcher import ROOT, prepare_config


@unittest.skipUnless(shutil.which('docker'), 'Docker CLI is not installed')
class ComposeConfigTests(unittest.TestCase):
    def config(self, mode, filename, **options):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = prepare_config(root, mode, port=18080, **options)
            shutil.copyfile(ROOT / filename, root / filename)
            result = subprocess.run([
                'docker', 'compose', '--project-name', 'smart-meeting-test',
                '--env-file', str(root / f'.runtime/{mode}.env'),
                '-f', str(root / filename), 'config', '--format', 'json',
            ], capture_output=True, text=True, encoding='utf-8', check=True)
            return json.loads(result.stdout), config

    def test_explicit_host_publishes_web_and_media_on_requested_interfaces(self):
        for mode, filename in [('local', 'compose.recording.yaml'), ('docker', 'compose.yaml')]:
            compose, _ = self.config(mode, filename, host='0.0.0.0')
            for service in ['livekit'] + (['web'] if mode == 'docker' else []):
                self.assertTrue(all(p['host_ip'] == '0.0.0.0' for p in compose['services'][service]['ports']))

    def test_docker_services_have_recording_dependencies_and_shared_storage(self):
        compose, config = self.config('docker', 'compose.yaml')
        services = compose['services']
        self.assertEqual(set(services), {'web', 'livekit', 'redis', 'egress', 'turn'})
        self.assertEqual(services['turn']['network_mode'], 'service:livekit')
        self.assertEqual(services['egress']['network_mode'], 'service:livekit')
        self.assertEqual(services['egress']['cap_add'], ['SYS_ADMIN'])
        self.assertIn('healthcheck', services['egress'])
        self.assertEqual(services['egress']['depends_on']['web']['condition'], 'service_healthy')
        mounts = [next(v for v in services[name]['volumes'] if v['target'] == '/recordings')['source']
                  for name in ['web', 'egress']]
        self.assertEqual(mounts[0], mounts[1])
        self.assertEqual(services['web']['environment']['LIVEKIT_API_SECRET'], config['LIVEKIT_API_SECRET'])
        self.assertEqual(services['web']['environment']['DEBUG'], '0')
        self.assertTrue(all(p['host_ip'] == '127.0.0.1' for p in services['web']['ports']))

    def test_local_recording_shares_media_network_and_has_host_callback(self):
        compose, _ = self.config('local', 'compose.recording.yaml')
        services = compose['services']
        self.assertEqual(set(services), {'redis', 'livekit', 'egress', 'turn'})
        self.assertEqual(services['turn']['network_mode'], 'service:livekit')
        self.assertNotIn('ports', services['redis'])
        self.assertEqual(services['egress']['network_mode'], 'service:livekit')
        self.assertIn('host.docker.internal', str(services['livekit']['extra_hosts']))
        self.assertTrue(all(p['host_ip'] == '127.0.0.1' for p in services['livekit']['ports']))
        self.assertIn('healthcheck', services['egress'])
