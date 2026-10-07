"""Build wheels with an audited source allowlist and precompiled Flutter Web."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path

from setuptools.command.build_py import build_py
from setuptools.command.sdist import sdist

ROOT = Path(__file__).resolve().parent

# PEP 517 imports command classes without adding the source root to sys.path.
_package_spec = importlib.util.spec_from_file_location('_vibemeeting_build_package', ROOT / 'vibemeeting/__init__.py')
_package = importlib.util.module_from_spec(_package_spec)
sys.modules[_package_spec.name] = _package
_package_spec.loader.exec_module(_package)
_cli_spec = importlib.util.spec_from_file_location('_vibemeeting_build_package.cli', ROOT / 'vibemeeting/cli.py')
_cli = importlib.util.module_from_spec(_cli_spec)
_cli_spec.loader.exec_module(_cli)
safe_target, write_manifest = _cli.safe_target, _cli.write_manifest


def frontend_fingerprint(root):
    paths = [p for folder in ['lib', 'web'] for p in (root / 'flutter_app' / folder).rglob('*') if p.is_file()]
    paths += [root / 'flutter_app/pubspec.yaml', root / 'flutter_app/pubspec.lock']
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def ensure_frontend(root):
    frontend = root / 'artifacts/flutter_app_web'
    stamp = frontend / '.vibemeeting-sources.sha256'
    fingerprint = frontend_fingerprint(root)
    if not (frontend / 'index.html').is_file() or not stamp.is_file() or stamp.read_text() != fingerprint:
        spec = importlib.util.spec_from_file_location('_vibemeeting_build_launcher', root / 'scripts/launcher.py')
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)
        flutter = launcher.ensure_flutter(root)
        launcher.run([flutter, 'pub', 'get'], cwd=root / 'flutter_app')
        launcher.run([flutter, 'build', 'web', '--release', '--no-pub', '--no-wasm-dry-run'], cwd=root / 'flutter_app')
        launcher.publish_frontend(root)
        stamp.write_text(fingerprint, encoding='utf-8')
    return frontend


def reset_generated_bundle(destination):
    if destination.is_symlink():
        raise ValueError('Refusing a linked build directory.')
    if destination.exists() and any(destination.iterdir()):
        manifest_path = destination / 'bundle-manifest.json'
        if not manifest_path.is_file():
            raise ValueError('Refusing to replace an unmanaged build directory.')
        old = json.loads(manifest_path.read_text(encoding='utf-8'))['files']
        existing = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file()}
        if existing != set(old) | {'bundle-manifest.json'}:
            raise ValueError('Unexpected files in generated bundle; use a clean build directory.')
        for name in old:
            safe_target(destination, name).unlink()
        manifest_path.unlink()
    destination.mkdir(parents=True, exist_ok=True)


def populate_bundle(root, destination):
    prebuilt = root / 'vibemeeting/_app'
    if (prebuilt / 'bundle-manifest.json').is_file():
        manifest = json.loads((prebuilt / 'bundle-manifest.json').read_text(encoding='utf-8'))
        sources = [(safe_target(prebuilt, name), name) for name in manifest['files']]
        for source, name in sources:
            if hashlib.sha256(source.read_bytes()).hexdigest() != manifest['files'][name]:
                raise ValueError('Prebuilt application integrity check failed.')
    else:
        frontend = ensure_frontend(root)
        sources = []
        for folder in ['conference', 'smart_meeting']:
            sources.extend((p, p.relative_to(root).as_posix()) for p in (root / folder).rglob('*.py')
                           if not p.name.startswith('test') and '__pycache__' not in p.parts)
        sources.extend((p, p.relative_to(root).as_posix()) for p in (root / 'app/templates').rglob('*') if p.is_file())
        for name in ['app/static/meeting-room.js', 'app/static/style.css',
                     'app/static/brand/vibemeeting-logo.png', 'manage.py',
                     'requirements.txt', 'compose.recording.yaml', 'scripts/launcher.py', 'LICENSE', 'NOTICE']:
            sources.append((root / name, name))
        sources.extend((p, 'artifacts/flutter_app_web/' + p.relative_to(frontend).as_posix())
                       for p in frontend.rglob('*') if p.is_file() and not p.name.startswith('.'))
    reset_generated_bundle(destination)
    for source, name in sources:
        if source.is_symlink():
            raise ValueError('Linked source files cannot be packaged.')
        target = safe_target(destination, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    write_manifest(destination)


class BuildPy(build_py):
    def run(self):
        super().run()
        populate_bundle(ROOT, Path(self.build_lib) / 'vibemeeting/_app')


class SourceDistribution(sdist):
    def make_release_tree(self, base_dir, files):
        super().make_release_tree(base_dir, files)
        populate_bundle(ROOT, Path(base_dir) / 'vibemeeting/_app')
