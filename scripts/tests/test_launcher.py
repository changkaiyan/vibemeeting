"""Installer lifecycle tests; no network or global environment changes."""
import json
import socket
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from scripts import launcher


class LauncherTests(unittest.TestCase):
    def test_remote_turn_uses_routable_interface_and_preserves_local_loopback(self):
        for mode in ['local', 'docker']:
            launcher.prepare_config(self.root, mode, livekit_node_ip='192.0.2.10')
            rtc = json.loads((self.root / f'.runtime/{mode}-livekit.yaml').read_text())['rtc']
            self.assertFalse(rtc['enable_loopback_candidate'])
            path = self.root / f'.runtime/{mode}-turn.conf'
            self.assertFalse(any(line.startswith('relay-ip=') for line in path.read_text().splitlines()))
            launcher.prepare_config(self.root, mode, livekit_node_ip='127.0.0.1')
            self.assertIn('relay-ip=127.0.0.1', path.read_text())

    def test_remote_addresses_persist_and_configure_media_and_web(self):
        first = launcher.prepare_config(self.root, 'local', host='0.0.0.0',
            public_url='https://meeting.example.com',
            livekit_url='ws://127.0.0.1:17880',
            livekit_public_url='wss://rtc.example.com',
            livekit_node_ip='192.0.2.10', turn_host='turn.example.com')
        self.assertEqual(first['INSTALL_BIND_HOST'], '0.0.0.0')
        self.assertEqual(first['INSTALL_PUBLISH_HOST'], '0.0.0.0')
        self.assertIn('meeting.example.com', first['ALLOWED_HOSTS'])
        self.assertIn('https://meeting.example.com', first['CSRF_TRUSTED_ORIGINS'])
        again = launcher.prepare_config(self.root, 'local', port=18000)
        for key in ['INSTALL_BIND_HOST', 'INSTALL_PUBLIC_URL', 'LIVEKIT_URL',
                    'LIVEKIT_PUBLIC_URL', 'INSTALL_NODE_IP', 'INSTALL_TURN_HOST']:
            self.assertEqual(first[key], again[key], key)
        media = json.loads((self.root / '.runtime/local-livekit.yaml').read_text())
        self.assertEqual(media['rtc']['node_ip'], '192.0.2.10')
        self.assertEqual(media['rtc']['turn_servers'][0]['host'], 'turn.example.com')

    def test_invalid_network_options_do_not_modify_existing_config(self):
        launcher.prepare_config(self.root, 'local')
        path = self.root / '.runtime/local.env'
        before = path.read_bytes()
        for options in [{'host': 'bad host'}, {'public_url': 'https://user:pass@example.com'},
                        {'public_url': 'https://0.0.0.0'}, {'livekit_public_url': 'https://rtc.example.com'},
                        {'livekit_node_ip': '0.0.0.0'}, {'turn_host': 'bad\nhost'},
                        {'csrf_trusted_origins': 'https://example.com/path'}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                launcher.prepare_config(self.root, 'local', **options)
            self.assertEqual(path.read_bytes(), before)

    def test_cli_passes_network_options_into_configuration(self):
        with patch.object(launcher, 'ROOT', self.root):
            self.assertEqual(launcher.main(['local', '--prepare-only', '--host', '0.0.0.0',
                '--public-url', 'http://meeting.example.com:8000',
                '--livekit-public-url', 'ws://rtc.example.com:7880',
                '--livekit-node-ip', '192.0.2.10']), 0)
        self.assertEqual(launcher.read_env(self.root / '.runtime/local.env')['INSTALL_BIND_HOST'], '0.0.0.0')

    def test_specific_interface_uses_reachable_backend_address(self):
        config = launcher.prepare_config(self.root, 'local', host='127.0.0.2')
        self.assertEqual(config['LIVEKIT_URL'], 'ws://127.0.0.2:7880')
        self.assertEqual(config['LIVEKIT_PUBLIC_URL'], 'ws://127.0.0.2:7880')
        changed = launcher.prepare_config(self.root, 'local', host='127.0.0.3')
        self.assertEqual(changed['LIVEKIT_URL'], 'ws://127.0.0.3:7880')
        self.assertEqual(changed['LIVEKIT_PUBLIC_URL'], 'ws://127.0.0.3:7880')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_first_install_creates_private_config_without_touching_user_env(self):
        original = self.root / '.env'
        original.write_text('SECRET_KEY=keep-me\n', encoding='utf-8')
        config = launcher.prepare_config(self.root, 'local')
        self.assertEqual(original.read_text(), 'SECRET_KEY=keep-me\n')
        self.assertGreaterEqual(len(config['SECRET_KEY']), 32)
        self.assertGreaterEqual(len(config['LIVEKIT_API_SECRET']), 32)
        self.assertGreaterEqual(len(config['DJANGO_SUPERUSER_PASSWORD']), 20)
        self.assertNotEqual(config['SECRET_KEY'], config['LIVEKIT_API_SECRET'])
        self.assertEqual(config['LIVEKIT_PUBLIC_URL'], 'ws://127.0.0.1:7880')
        self.assertIn('/.runtime/data/', config['DATABASE_URL'])

    def test_repeated_install_preserves_credentials_and_port_customization(self):
        first = launcher.prepare_config(self.root, 'local', port=18000)
        again = launcher.prepare_config(self.root, 'local')
        self.assertEqual(first, again)
        changed = launcher.prepare_config(self.root, 'local', livekit_port=17880)
        self.assertEqual(first['DJANGO_SUPERUSER_PASSWORD'], changed['DJANGO_SUPERUSER_PASSWORD'])
        self.assertEqual(changed['INSTALL_WEB_PORT'], '18000')
        self.assertEqual(changed['LIVEKIT_PUBLIC_URL'], 'ws://127.0.0.1:17880')

    def test_docker_config_uses_service_dns_and_persistent_volume(self):
        config = launcher.prepare_config(self.root, 'docker', port=18080, rtc_tcp_port=17881)
        self.assertEqual(config['LIVEKIT_URL'], 'ws://livekit:7880')
        self.assertEqual(config['DATABASE_URL'], 'sqlite:////data/smart_meeting.db')
        livekit = json.loads((self.root / '.runtime/docker-livekit.yaml').read_text())
        self.assertEqual(livekit['keys'], {config['LIVEKIT_API_KEY']: config['LIVEKIT_API_SECRET']})
        self.assertEqual(livekit['rtc']['tcp_port'], 17881)
        self.assertEqual(livekit['rtc']['node_ip'], '127.0.0.1')
        self.assertTrue(livekit['rtc']['enable_loopback_candidate'])
        self.assertEqual(livekit['webhook']['urls'], ['http://web:8000/api/livekit/webhook'])
        self.assertEqual(livekit['redis']['address'], 'redis:6379')
        egress = json.loads((self.root / '.runtime/docker-egress.yaml').read_text())
        self.assertEqual(egress['redis']['address'], livekit['redis']['address'])
        self.assertEqual(egress['api_secret'], config['LIVEKIT_API_SECRET'])
        self.assertEqual(egress['ws_url'], 'ws://127.0.0.1:7880')
        self.assertEqual(config['RECORDING_STORAGE_ROOT'], '/recordings')
        self.assertEqual(config['LIVEKIT_EGRESS_OUTPUT_ROOT'], '/recordings')

    def test_local_media_shares_loopback_network_and_calls_back_to_host_web(self):
        config = launcher.prepare_config(self.root, 'local', livekit_port=27880)
        livekit = json.loads((self.root / '.runtime/local-livekit.yaml').read_text())
        egress = json.loads((self.root / '.runtime/local-egress.yaml').read_text())
        self.assertEqual(livekit['redis']['address'], 'redis:6379')
        self.assertEqual(livekit['rtc']['node_ip'], '127.0.0.1')
        self.assertEqual(livekit['port'], 7880)
        self.assertEqual(egress['ws_url'], 'ws://127.0.0.1:7880')
        self.assertEqual(egress['redis']['address'], 'redis:6379')
        self.assertEqual(config['LIVEKIT_EGRESS_OUTPUT_ROOT'], '/recordings')
        self.assertEqual(livekit['webhook']['urls'], ['http://host.docker.internal:8000/api/livekit/webhook'])
        self.assertIn('host.docker.internal', config['ALLOWED_HOSTS'])

    def test_both_modes_offer_authenticated_tcp_turn_for_desktop_docker(self):
        for mode in ['local', 'docker']:
            config = launcher.prepare_config(self.root, mode, turn_port=13478)
            livekit = json.loads((self.root / f'.runtime/{mode}-livekit.yaml').read_text())
            turn = livekit['rtc']['turn_servers'][0]
            self.assertEqual(turn['host'], '127.0.0.1')
            self.assertEqual(turn['port'], 13478)
            self.assertEqual(turn['protocol'], 'tcp')
            self.assertEqual(turn['credential'], config['TURN_PASSWORD'])
            self.assertGreaterEqual(len(turn['credential']), 32)
            coturn = (self.root / f'.runtime/{mode}-turn.conf').read_text()
            self.assertIn('allow-loopback-peers', coturn)
            self.assertIn('listening-port=13478', coturn)
            self.assertIn('user=meeting:' + turn['credential'], coturn)

    def test_linux_local_web_accepts_docker_gateway_callbacks(self):
        with patch('scripts.launcher.sys.platform', 'linux'):
            config = launcher.prepare_config(self.root, 'local')
        self.assertEqual(config['INSTALL_BIND_HOST'], '0.0.0.0')
        self.assertIn('host.docker.internal', config['ALLOWED_HOSTS'])

    def test_invalid_or_duplicate_ports_fail_before_writing_config(self):
        for kwargs in ({'port': 0}, {'port': 70000}, {'port': 7880}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                launcher.prepare_config(self.root, 'local', **kwargs)
        self.assertFalse((self.root / '.runtime/local.env').exists())

    def test_occupied_port_fails_without_terminating_other_services(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, 'port|Port'):
                launcher.check_ports([('web', listener.getsockname()[1], socket.SOCK_STREAM)])
            self.assertNotEqual(listener.fileno(), -1)

    def test_frontend_copy_replaces_stale_files(self):
        source = self.root / 'flutter_app/build/web'
        target = self.root / 'artifacts/flutter_app_web'
        source.mkdir(parents=True)
        target.mkdir(parents=True)
        (source / 'index.html').write_text('current')
        (target / 'old-worker.js').write_text('old')
        launcher.publish_frontend(self.root)
        self.assertEqual((target / 'index.html').read_text(), 'current')
        self.assertFalse((target / 'old-worker.js').exists())

    def test_service_failure_terminates_only_children_started_by_launcher(self):
        first, second = Mock(), Mock()
        first.poll.return_value = None
        second.poll.return_value = 1
        with self.assertRaisesRegex(RuntimeError, 'web'):
            launcher.supervise([('livekit', first), ('web', second)], poll_interval=0)
        first.terminate.assert_called_once()
        first.wait.assert_called_once()
        second.terminate.assert_not_called()

    def test_warm_startup_skips_install_and_build_until_inputs_change(self):
        inputs = self.root / 'requirements.txt'
        inputs.write_text('first')
        stamp = self.root / '.runtime/deps.sha256'
        self.assertTrue(launcher.inputs_changed(stamp, [inputs]))
        launcher.record_inputs(stamp, [inputs])
        self.assertFalse(launcher.inputs_changed(stamp, [inputs]))
        inputs.write_text('second')
        self.assertTrue(launcher.inputs_changed(stamp, [inputs]))


if __name__ == '__main__':
    unittest.main()
