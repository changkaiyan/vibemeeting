"""One-command localhost installation. Bootstrap uses only the Python stdlib."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlsplit
from pathlib import Path

FLUTTER_VERSION = '3.41.6'
ROOT = Path(__file__).resolve().parents[1]
NETWORK_OPTIONS = {
    'host': 'Web and managed media bind IPv4 address (for example 0.0.0.0).',
    'public_url': 'Browser-facing Web origin, for example https://meeting.example.com.',
    'livekit_url': 'Backend LiveKit API URL (ws:// or wss://).',
    'livekit_public_url': 'Browser-facing LiveKit URL (ws:// or wss://).',
    'livekit_node_ip': 'Reachable IPv4 address advertised by managed LiveKit.',
    'turn_host': 'Reachable hostname or IPv4 address advertised for managed TURN.',
    'allowed_hosts': 'Additional comma-separated Django hostnames.',
    'csrf_trusted_origins': 'Additional comma-separated HTTP/HTTPS origins.',
}


def validate_host(value):
    import re
    if not value or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', value):
        raise ValueError('Expected a hostname or IPv4 address without a scheme or port.')
    return value


def validate_url(value, schemes, *, origin=False):
    parsed = urlsplit(value)
    if (any(c.isspace() for c in value) or parsed.scheme not in schemes or
            not parsed.hostname or parsed.username is not None or parsed.password is not None or
            parsed.query or parsed.fragment or (origin and parsed.path not in ('', '/'))):
        raise ValueError('Invalid address: use an HTTP(S) origin or WS(S) LiveKit URL without credentials.')
    validate_host(parsed.hostname)
    if parsed.hostname in ('0.0.0.0', str(ipaddress.IPv4Address(0xFFFFFFFF))):
        raise ValueError('Public URLs must use a reachable hostname or address, not a wildcard bind address.')
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError('Invalid URL port.')
    return value.rstrip('/')


def read_env(path):
    result = {}
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            if line.strip() and not line.lstrip().startswith('#'):
                key, sep, value = line.partition('=')
                if not sep:
                    raise ValueError(f'Invalid configuration line in {path}')
                result[key] = value
    return result


def prepare_config(root, mode, *, port=None, livekit_port=None,
                   rtc_tcp_port=None, rtc_udp_port=None, turn_port=None, host_root=None,
                   host=None, public_url=None, livekit_url=None, livekit_public_url=None,
                   livekit_node_ip=None, turn_host=None, allowed_hosts=None, csrf_trusted_origins=None):
    runtime = root / '.runtime'
    config = read_env(runtime / f'{mode}.env')
    old_signal_port = config.get('INSTALL_LIVEKIT_PORT', '7880')
    old_media_host = config.get('INSTALL_PUBLISH_HOST', '127.0.0.1')
    old_media_host = '127.0.0.1' if old_media_host == '0.0.0.0' else old_media_host
    old_public_host = config.get('INSTALL_NODE_IP', '127.0.0.1')
    if old_public_host == '127.0.0.1':
        old_public_host = old_media_host
    network = json.loads(config.get('INSTALL_NETWORK_OPTIONS', '{}'))
    if not isinstance(network, dict) or any(k not in NETWORK_OPTIONS or not isinstance(v, str) for k, v in network.items()):
        raise ValueError('Invalid saved network options.')
    supplied = dict(host=host, public_url=public_url, livekit_url=livekit_url,
                    livekit_public_url=livekit_public_url, livekit_node_ip=livekit_node_ip,
                    turn_host=turn_host, allowed_hosts=allowed_hosts, csrf_trusted_origins=csrf_trusted_origins)
    network.update({k: v for k, v in supplied.items() if v is not None})
    if 'host' in network:
        network['host'] = str(ipaddress.IPv4Address('127.0.0.1' if network['host'] == 'localhost' else network['host']))
    if 'livekit_node_ip' in network:
        node = ipaddress.IPv4Address(network['livekit_node_ip'])
        if node.is_unspecified or node.is_multicast or int(node) == 0xFFFFFFFF:
            raise ValueError('LiveKit node IP must be a reachable unicast address.')
    if 'turn_host' in network:
        validate_host(network['turn_host'])
        if network['turn_host'] == '0.0.0.0':
            raise ValueError('TURN host must be reachable.')
    for key in ['public_url', 'livekit_url', 'livekit_public_url']:
        if key in network:
            network[key] = validate_url(network[key], ('http', 'https') if key == 'public_url' else ('ws', 'wss'), origin=key == 'public_url')
    for item in network.get('allowed_hosts', '').split(','):
        if item.strip():
            validate_host(item.strip())
    for item in network.get('csrf_trusted_origins', '').split(','):
        if item.strip():
            validate_url(item.strip(), ('http', 'https'), origin=True)
    config['INSTALL_NETWORK_OPTIONS'] = json.dumps(network, separators=(',', ':'))
    config.setdefault('SECRET_KEY', secrets.token_hex(32))
    config.setdefault('LIVEKIT_API_KEY', 'meeting_' + secrets.token_hex(8))
    config.setdefault('LIVEKIT_API_SECRET', secrets.token_hex(32))
    config.setdefault('TURN_PASSWORD', secrets.token_hex(32))
    config.setdefault('DJANGO_SUPERUSER_USERNAME', 'admin')
    config.setdefault('DJANGO_SUPERUSER_PASSWORD', secrets.token_urlsafe(24))
    config.setdefault('DJANGO_SUPERUSER_EMAIL', 'admin@localhost')
    ports = {
        'INSTALL_WEB_PORT': (port, 8080 if mode == 'docker' else 8000),
        'INSTALL_LIVEKIT_PORT': (livekit_port, 7880),
        'INSTALL_RTC_TCP_PORT': (rtc_tcp_port, 7881),
        'INSTALL_RTC_UDP_PORT': (rtc_udp_port, 7882),
        'INSTALL_TURN_PORT': (turn_port, 3478),
    }
    for name, (value, default) in ports.items():
        config[name] = str(value if value is not None else config.get(name, default))
    numbers = [int(config[key]) for key in ports]
    if any(p < 1024 or p > 65535 for p in numbers) or len(set(numbers)) != len(numbers):
        raise ValueError('Ports must be distinct numbers between 1024 and 65535.')
    config['INSTALL_NODE_IP'] = network.get('livekit_node_ip', config.get('INSTALL_NODE_IP', '127.0.0.1'))
    # Linux Docker's host-gateway cannot reach a host process bound to loopback.
    config['INSTALL_BIND_HOST'] = network.get('host', config.get('INSTALL_BIND_HOST',
        '127.0.0.1' if mode == 'local' and sys.platform == 'win32' else '0.0.0.0'))
    config['INSTALL_PUBLISH_HOST'] = network.get('host', config.get('INSTALL_PUBLISH_HOST', '127.0.0.1'))
    config['INSTALL_TURN_HOST'] = network.get('turn_host', config['INSTALL_NODE_IP'])
    web_port, signal_port = config['INSTALL_WEB_PORT'], config['INSTALL_LIVEKIT_PORT']
    visit_host = config['INSTALL_BIND_HOST'] if config['INSTALL_BIND_HOST'] != '0.0.0.0' else '127.0.0.1'
    media_host = config['INSTALL_PUBLISH_HOST'] if config['INSTALL_PUBLISH_HOST'] != '0.0.0.0' else '127.0.0.1'
    rtc_public_host = config['INSTALL_NODE_IP'] if config['INSTALL_NODE_IP'] != '127.0.0.1' else media_host
    config['INSTALL_PUBLIC_URL'] = network.get('public_url', f'http://{visit_host}:{web_port}')
    public_host = urlsplit(config['INSTALL_PUBLIC_URL']).hostname
    hosts = ['127.0.0.1', 'localhost', 'web', 'host.docker.internal', visit_host, public_host]
    hosts.extend(x.strip() for x in network.get('allowed_hosts', '').split(',') if x.strip())
    origins = [f'http://127.0.0.1:{web_port}', f'http://localhost:{web_port}', config['INSTALL_PUBLIC_URL']]
    origins.extend(x.strip().rstrip('/') for x in network.get('csrf_trusted_origins', '').split(',') if x.strip())
    recordings = (str(host_root).replace('\\', '/').rstrip('/') if host_root else root.as_posix()) + '/.runtime/recordings'
    config['INSTALL_RECORDINGS_DIR'] = recordings
    defaults = {
        'DEBUG': '0', 'HTTPS_TEST': '0', 'ALLOWED_HOSTS': ','.join(dict.fromkeys(hosts)),
        'CSRF_TRUSTED_ORIGINS': ','.join(dict.fromkeys(origins)),
        'DATABASE_URL': 'sqlite:////data/smart_meeting.db' if mode == 'docker' else
                        'sqlite:///' + (runtime / 'data/smart_meeting.db').as_posix(),
        'LIVEKIT_URL': 'ws://livekit:7880' if mode == 'docker' else f'ws://{media_host}:{signal_port}',
        'LIVEKIT_PUBLIC_URL': f'ws://{rtc_public_host}:{signal_port}',
        'LIVEKIT_EGRESS_OUTPUT_ROOT': '/recordings',
        'RECORDING_STORAGE_ROOT': '/recordings' if mode == 'docker' else recordings,
        'MEETING_STT_PROVIDER': 'disabled', 'MEETING_REALTIME_STT_WORKER_URL': '',
        'MEETING_AGENT_BRIDGE_MODE': 'disabled', 'MEETING_AGENT_BRIDGE_URL': '',
    }
    for key, option, old_default in [
        ('LIVEKIT_URL', 'livekit_url', 'ws://livekit:7880' if mode == 'docker' else f'ws://{old_media_host}:{old_signal_port}'),
        ('LIVEKIT_PUBLIC_URL', 'livekit_public_url', f'ws://{old_public_host}:{old_signal_port}')]:
        saved = config.get(key, old_default)
        defaults[key] = network.get(option, saved if saved != old_default else defaults[key])
        validate_url(defaults[key], ('ws', 'wss'))
    # Address-derived values follow port changes; optional integrations remain editable.
    for key, value in defaults.items():
        if key.startswith('MEETING_'):
            config.setdefault(key, value)
        else:
            config[key] = value
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    (runtime / 'data').mkdir(exist_ok=True)
    recording_dir = runtime / 'recordings'
    if not recording_dir.exists():
        recording_dir.mkdir(mode=0o777)
        recording_dir.chmod(0o777)  # Official Egress image writes as an unprivileged user.
    for key, value in config.items():
        if '\n' in value or '\r' in value:
            raise ValueError(f'Multiline configuration is not supported: {key}')
    env_file = runtime / f'{mode}.env'
    env_file.write_text(''.join(f'{key}={value}\n' for key, value in sorted(config.items())), encoding='utf-8')
    env_file.chmod(0o600)
    livekit = {
        'port': 7880,
        'bind_addresses': ['0.0.0.0'],
        'rtc': {'tcp_port': int(config['INSTALL_RTC_TCP_PORT']),
                'udp_port': int(config['INSTALL_RTC_UDP_PORT']),
                'use_external_ip': False, 'node_ip': config['INSTALL_NODE_IP'],
                'enable_loopback_candidate': True,
                'turn_servers': [{'host': config['INSTALL_TURN_HOST'], 'port': int(config['INSTALL_TURN_PORT']),
                                  'protocol': 'tcp', 'username': 'meeting',
                                  'credential': config['TURN_PASSWORD']}]},
        'keys': {config['LIVEKIT_API_KEY']: config['LIVEKIT_API_SECRET']},
        'redis': {'address': 'redis:6379'},
        'webhook': {'api_key': config['LIVEKIT_API_KEY'], 'urls': [
            'http://web:8000/api/livekit/webhook' if mode == 'docker' else
            f'http://host.docker.internal:{web_port}/api/livekit/webhook']},
    }
    egress = {
        'api_key': config['LIVEKIT_API_KEY'], 'api_secret': config['LIVEKIT_API_SECRET'],
        'ws_url': 'ws://127.0.0.1:7880',
        'redis': {'address': 'redis:6379'}, 'insecure': True, 'health_port': 8081,
    }
    for name, data in [('livekit', livekit), ('egress', egress)]:
        path = runtime / f'{mode}-{name}.yaml'
        # JSON is also YAML; avoid a bootstrap dependency on PyYAML.
        path.write_text(json.dumps(data, indent=2), encoding='utf-8')
        path.chmod(0o644)  # Mounted into containers; parent .runtime is private.
    turn_file = runtime / f'{mode}-turn.conf'
    turn_file.write_text('\n'.join([
        'listening-ip=0.0.0.0', f"listening-port={config['INSTALL_TURN_PORT']}",
        'relay-ip=127.0.0.1', 'min-port=40000', 'max-port=40100',
        'realm=smart-meeting.local', 'lt-cred-mech', 'fingerprint',
        'user=meeting:' + config['TURN_PASSWORD'], 'allow-loopback-peers',
        'no-multicast-peers', 'no-cli', 'no-tls', 'no-dtls', 'no-udp',
        'log-file=stdout', 'simple-log',
    ]) + '\n', encoding='utf-8')
    turn_file.chmod(0o644)
    return config


def run(command, *, cwd=ROOT, env=None):
    print('Running: ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def check_ports(ports):
    for name, port, kind in ports:
        with socket.socket(socket.AF_INET, kind) as probe:
            if os.name == 'nt':
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            try:
                probe.bind(('0.0.0.0', port))
            except OSError as exc:
                raise RuntimeError(f'{name} port {port} is already in use. Change the port; no existing process was stopped.') from exc


def ensure_flutter(root):
    name = 'flutter.bat' if os.name == 'nt' else 'flutter'
    for candidate in [root / 'tools/flutter/bin' / name, root / '.runtime/tools/flutter/bin' / name]:
        if candidate.exists():
            return candidate
    if shutil.which('flutter'):
        return Path(shutil.which('flutter'))
    if not shutil.which('git'):
        raise RuntimeError('Git is required to install Flutter. Install Git and rerun.')
    destination = root / '.runtime/tools/flutter'
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(['git', 'clone', '--depth', '1', '--branch', FLUTTER_VERSION,
         'https://github.com/flutter/flutter.git', destination], cwd=root)
    return destination / 'bin' / name


def inputs_digest(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def inputs_changed(stamp, paths):
    return not stamp.exists() or stamp.read_text() != inputs_digest(paths)


def record_inputs(stamp, paths):
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(inputs_digest(paths))


def publish_frontend(root):
    source = root / 'flutter_app/build/web'
    if not (source / 'index.html').is_file():
        raise RuntimeError('Flutter build did not produce index.html')
    destination = root / 'artifacts/flutter_app_web'
    if destination.is_symlink():
        raise RuntimeError('Refusing to replace a linked build directory')
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def supervise(children, poll_interval=1):
    try:
        while True:
            for name, child in children:
                if child.poll() is not None:
                    raise RuntimeError(f'{name} exited unexpectedly. Check .runtime/logs/.')
            time.sleep(poll_interval)
    finally:
        for _, child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


def wait_http(url, children, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for name, child in children:
            if child.poll() is not None:
                raise RuntimeError(f'{name} failed to start. Check .runtime/logs/.')
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(1)
    raise RuntimeError(f'Timed out waiting for {url}')


def show_access(config, mode):
    print(f"\nOpen {config.get('INSTALL_PUBLIC_URL', 'http://127.0.0.1:' + config['INSTALL_WEB_PORT'])}/accounts/login")
    print(f"Admin: {config['DJANGO_SUPERUSER_USERNAME']}")
    print(f'Initial password is in .runtime/{mode}.env (DJANGO_SUPERUSER_PASSWORD).')
    print('Recording files: .runtime/recordings/\n', flush=True)


def local(args):
    config = prepare_config(ROOT, 'local', **config_options(args))
    if args.prepare_only:
        show_access(config, 'local')
        return
    if not shutil.which('docker'):
        raise RuntimeError('Docker with Compose is required for LiveKit, Redis and meeting recording (Egress).')
    run(['docker', 'info', '--format', '{{.ServerVersion}}'])
    check_ports([(key, int(config[key]), kind) for key, kind in [
        ('INSTALL_WEB_PORT', socket.SOCK_STREAM), ('INSTALL_LIVEKIT_PORT', socket.SOCK_STREAM),
        ('INSTALL_RTC_TCP_PORT', socket.SOCK_STREAM), ('INSTALL_RTC_UDP_PORT', socket.SOCK_DGRAM),
        ('INSTALL_TURN_PORT', socket.SOCK_STREAM)]])
    runtime = ROOT / '.runtime'
    packaged = getattr(args, 'packaged', False)
    venv = runtime / 'venv'
    python = Path(sys.executable) if packaged else venv / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
    if not python.exists():
        run([sys.executable, '-m', 'venv', venv])
    env = {**os.environ, **config, 'PYTHONUNBUFFERED': '1', 'PYTHONUTF8': '1'}
    requirements = [ROOT / 'requirements.txt']
    stamp = runtime / 'dependencies.sha256'
    if not packaged and inputs_changed(stamp, requirements):
        run([python, '-m', 'pip', 'install', '--disable-pip-version-check', '--progress-bar', 'off',
             '-r', requirements[0]], env=env)
        record_inputs(stamp, requirements)
    inputs = [p for folder in ['lib', 'web'] for p in (ROOT / 'flutter_app' / folder).rglob('*') if p.is_file()]
    inputs += [ROOT / 'flutter_app/pubspec.yaml', ROOT / 'flutter_app/pubspec.lock']
    stamp = runtime / 'frontend.sha256'
    if packaged and not (ROOT / 'artifacts/flutter_app_web/index.html').is_file():
        raise RuntimeError('Packaged frontend is missing. Reinstall the VibeMeeting wheel.')
    if not packaged and (args.rebuild or inputs_changed(stamp, inputs) or not (ROOT / 'artifacts/flutter_app_web/index.html').exists()):
        flutter = ensure_flutter(ROOT)
        run([flutter, 'pub', 'get'], cwd=ROOT / 'flutter_app', env=env)
        run([flutter, 'build', 'web', '--no-pub', '--no-wasm-dry-run'], cwd=ROOT / 'flutter_app', env=env)
        publish_frontend(ROOT)
        record_inputs(stamp, inputs)
    run([python, 'manage.py', 'migrate', '--noinput'], env=env)
    run([python, 'manage.py', 'bootstrap_admin'], env=env)
    run([python, 'manage.py', 'collectstatic', '--noinput'], env=env)
    compose = ['docker', 'compose', '--project-name', getattr(args, 'project_name', None) or 'smart-meeting-local-recording',
               '--env-file', str(runtime / 'local.env'), '-f', 'compose.recording.yaml']
    children, logs = [], []
    try:
        log_dir = runtime / 'logs'
        log_dir.mkdir(exist_ok=True)
        commands = [
            ('web', [python, '-m', 'uvicorn', 'smart_meeting.asgi:application', '--host', config['INSTALL_BIND_HOST'],
                     '--port', config['INSTALL_WEB_PORT']]),
        ]
        for name, command in commands:
            output = (log_dir / f'{name}.log').open('a', encoding='utf-8')
            logs.append(output)
            options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
            children.append((name, subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env,
                                                   stdout=output, stderr=subprocess.STDOUT, **options)))
        probe_host = config['INSTALL_BIND_HOST'] if config['INSTALL_BIND_HOST'] != '0.0.0.0' else '127.0.0.1'
        wait_http(f"http://{probe_host}:{config['INSTALL_WEB_PORT']}/healthz", children)
        run(compose + ['up', '-d', '--force-recreate', '--wait', '--wait-timeout', '120'], env=env)
        media_host = config['INSTALL_PUBLISH_HOST'] if config['INSTALL_PUBLISH_HOST'] != '0.0.0.0' else '127.0.0.1'
        wait_http(f"http://{media_host}:{config['INSTALL_LIVEKIT_PORT']}/", children)
        show_access(config, 'local')
        print('Web, LiveKit, Redis, TURN and Egress are ready. Press Ctrl+C to stop.', flush=True)
        supervise(children)
    finally:
        for _, child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=15)
        for output in logs:
            output.close()
        run(compose + ['down'], env=env)  # No --volumes: data and recordings survive.


def config_options(args):
    return {key: getattr(args, key, None) for key in [
        'port', 'livekit_port', 'rtc_tcp_port', 'rtc_udp_port', 'turn_port', 'host_root', *NETWORK_OPTIONS]}


def main(argv=None):
    parser = argparse.ArgumentParser(description='Install and run VibeMeeting with recording.')
    parser.add_argument('mode', choices=['local', 'docker-config', 'docker-info'])
    for flag in ['port', 'livekit-port', 'rtc-tcp-port', 'rtc-udp-port', 'turn-port']:
        parser.add_argument('--' + flag, type=int)
    for flag, help_text in NETWORK_OPTIONS.items():
        parser.add_argument('--' + flag.replace('_', '-'), help=help_text)
    parser.add_argument('--host-root', help=argparse.SUPPRESS)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--packaged', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--project-name', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.mode == 'local':
            local(args)
        elif args.mode == 'docker-config':
            prepare_config(ROOT, 'docker', **config_options(args))
        else:
            show_access(read_env(ROOT / '.runtime/docker.env'), 'docker')
    except KeyboardInterrupt:
        print('\nStopped. Data and recordings are preserved.')
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f'Installation/start failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
