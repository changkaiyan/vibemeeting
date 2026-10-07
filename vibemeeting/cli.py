"""Run the bundled web application without modifying site-packages."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

from . import __version__

MARKER = '.vibemeeting-home.json'


def safe_target(root, name):
    relative = PurePosixPath(name)
    if (not relative.parts or relative.is_absolute() or '..' in relative.parts or
            ':' in name or '\\' in name or '.runtime' in relative.parts or name == MARKER):
        raise ValueError('Unsafe path in application manifest.')
    target = root / name
    if (target.is_symlink() or not target.resolve().is_relative_to(root.resolve()) or
            any(parent.is_symlink() for parent in target.parents if parent.is_relative_to(root))):
        raise ValueError('Refusing to write through a linked application path.')
    return target


def write_manifest(bundle):
    files = {path.relative_to(bundle).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(bundle.rglob('*'))
             if path.is_file() and path.name != 'bundle-manifest.json'}
    (bundle / 'bundle-manifest.json').write_text(
        json.dumps({'version': __version__, 'files': files}, indent=2), encoding='utf-8')


def claim_home(home):
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    marker = home / MARKER
    if marker.is_symlink():
        raise ValueError('Refusing a linked application marker.')
    if not marker.exists():
        if any(home.iterdir()):
            raise ValueError('Choose an empty data directory or an existing managed VibeMeeting directory.')
        marker.write_text(json.dumps({'version': None, 'files': {}}), encoding='utf-8')


def materialize(bundle, home):
    manifest = json.loads((bundle / 'bundle-manifest.json').read_text(encoding='utf-8'))
    files = manifest['files']
    for name, checksum in files.items():
        source = safe_target(bundle, name)
        if hashlib.sha256(source.read_bytes()).hexdigest() != checksum:
            raise ValueError('Bundled application checksum integrity check failed.')
        safe_target(home, name)
    claim_home(home)
    marker = home / MARKER
    previous = json.loads(marker.read_text(encoding='utf-8'))['files']
    for name in previous:
        safe_target(home, name)
    for name in files:
        destination = safe_target(home, name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        content = (bundle / name).read_bytes()
        if destination.is_file() and destination.read_bytes() == content:
            continue
        temporary = destination.with_name(destination.name + '.vibemeeting-tmp')
        if temporary.is_symlink():
            raise ValueError('Refusing a linked temporary application path.')
        temporary.write_bytes(content)
        temporary.replace(destination)
    for name in set(previous) - set(files):
        safe_target(home, name).unlink(missing_ok=True)
    marker.write_text(json.dumps(manifest, indent=2), encoding='utf-8')


@contextmanager
def instance_lock(home):
    runtime = home / '.runtime'
    if runtime.is_symlink():
        raise ValueError('Refusing a linked runtime directory.')
    runtime.mkdir(exist_ok=True, mode=0o700)
    lock_path = runtime / 'instance.lock'
    if lock_path.is_symlink():
        raise ValueError('Refusing a linked lock file.')
    with lock_path.open('a+b') as lock:
        lock.seek(0, 2)
        if not lock.tell():
            lock.write(b'\0')
            lock.flush()
        lock.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise RuntimeError('VibeMeeting is already running with this data directory.') from exc
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == 'nt':
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)


def load_launcher(home):
    spec = importlib.util.spec_from_file_location('_vibemeeting_launcher', home / 'scripts/launcher.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv=None):
    parser = argparse.ArgumentParser(description='Run VibeMeeting web meetings and recording. Docker with Compose is required.')
    parser.add_argument('command', nargs='?', default='run', choices=['run', 'info'])
    parser.add_argument('--version', action='version', version=f'vibemeeting {__version__}')
    parser.add_argument('--data-dir', type=Path, default=Path.home() / '.vibemeeting',
                        help='Persistent application and data directory (default: ~/.vibemeeting).')
    parser.add_argument('--prepare-only', action='store_true', help='Initialize files and credentials without starting services.')
    for flag in ['port', 'livekit-port', 'rtc-tcp-port', 'rtc-udp-port', 'turn-port']:
        parser.add_argument('--' + flag, type=int)
    args = parser.parse_args(argv)
    home = args.data_dir.expanduser().resolve()
    try:
        print(f'Data directory: {home}', flush=True)
        if args.command == 'info':
            if not (home / '.runtime/local.env').is_file() or not (home / MARKER).is_file():
                raise ValueError('No installation found. Run vibemeeting first.')
            module = load_launcher(home)
            module.show_access(module.read_env(home / '.runtime/local.env'), 'local')
            return 0
        bundle = Path(__file__).resolve().parent / '_app'
        if not (bundle / 'bundle-manifest.json').is_file():
            raise ValueError('Prebuilt application is missing. Install a built VibeMeeting wheel.')
        claim_home(home)
        with instance_lock(home):
            materialize(bundle, home)
            module = load_launcher(home)
            project = 'vibemeeting-' + hashlib.sha256(str(home).encode()).hexdigest()[:12]
            options = ['local', '--packaged', '--project-name', project]
            if args.prepare_only:
                options.append('--prepare-only')
            for flag in ['port', 'livekit_port', 'rtc_tcp_port', 'rtc_udp_port', 'turn_port']:
                value = getattr(args, flag)
                if value is not None:
                    options += ['--' + flag.replace('_', '-'), str(value)]
            return module.main(options)
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        print(f'VibeMeeting failed: {exc}', file=sys.stderr)
        return 1
