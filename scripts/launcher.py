"""One-command localhost installation. Bootstrap uses only the Python stdlib."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

FLUTTER_VERSION = '3.41.6'
ROOT = Path(__file__).resolve().parents[1]


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
                   rtc_tcp_port=None, rtc_udp_port=None, turn_port=None, host_root=None):
    runtime = root / '.runtime'
    config = read_env(runtime / f'{mode}.env')
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
    config['INSTALL_NODE_IP'] = '127.0.0.1'
    # Linux Docker's host-gateway cannot reach a host process bound to loopback.
    config['INSTALL_BIND_HOST'] = '127.0.0.1' if mode == 'local' and sys.platform == 'win32' else '0.0.0.0'
    web_port, signal_port = config['INSTALL_WEB_PORT'], config['INSTALL_LIVEKIT_PORT']
    recordings = (str(host_root).replace('\\', '/').rstrip('/') if host_root else root.as_posix()) + '/.runtime/recordings'
    config['INSTALL_RECORDINGS_DIR'] = recordings
    defaults = {
        'DEBUG': '0', 'HTTPS_TEST': '0', 'ALLOWED_HOSTS': '127.0.0.1,localhost,web,host.docker.internal',
        'CSRF_TRUSTED_ORIGINS': f'http://127.0.0.1:{web_port},http://localhost:{web_port}',
        'DATABASE_URL': 'sqlite:////data/smart_meeting.db' if mode == 'docker' else
                        'sqlite:///' + (runtime / 'data/smart_meeting.db').as_posix(),
        'LIVEKIT_URL': 'ws://livekit:7880' if mode == 'docker' else f'ws://127.0.0.1:{signal_port}',
        'LIVEKIT_PUBLIC_URL': f'ws://127.0.0.1:{signal_port}',
        'LIVEKIT_EGRESS_OUTPUT_ROOT': '/recordings',
        'RECORDING_STORAGE_ROOT': '/recordings' if mode == 'docker' else recordings,
        'MEETING_STT_PROVIDER': 'disabled', 'MEETING_REALTIME_STT_WORKER_URL': '',
        'MEETING_AGENT_BRIDGE_MODE': 'disabled', 'MEETING_AGENT_BRIDGE_URL': '',
    }
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
                'turn_servers': [{'host': '127.0.0.1', 'port': int(config['INSTALL_TURN_PORT']),
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
    print(f"\nOpen http://127.0.0.1:{config['INSTALL_WEB_PORT']}/accounts/login")
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
        wait_http(f"http://127.0.0.1:{config['INSTALL_WEB_PORT']}/healthz", children)
        run(compose + ['up', '-d', '--force-recreate', '--wait', '--wait-timeout', '120'], env=env)
        wait_http(f"http://127.0.0.1:{config['INSTALL_LIVEKIT_PORT']}/", children)
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
    return {key: getattr(args, key) for key in [
        'port', 'livekit_port', 'rtc_tcp_port', 'rtc_udp_port', 'turn_port', 'host_root']}


def main(argv=None):
    parser = argparse.ArgumentParser(description='Install and run Smart Meeting with recording.')
    parser.add_argument('mode', choices=['local', 'docker-config', 'docker-info'])
    for flag in ['port', 'livekit-port', 'rtc-tcp-port', 'rtc-udp-port', 'turn-port']:
        parser.add_argument('--' + flag, type=int)
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
