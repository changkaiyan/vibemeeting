"""Audit publishable Git files, then optionally export a source-only ZIP.

Findings contain locations and rules only, never matched credentials.
This is a release guard, not a proof that arbitrary data is non-sensitive.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import subprocess
import struct
from pathlib import Path, PurePosixPath
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
PRIVATE_PARTS = {'.git', '.runtime', '.venv', '.certs', '.runlogs', '__pycache__',
                 'tools', 'staticfiles', 'node_modules', '.dart_tool', 'build'}
PRIVATE_SUFFIXES = {'.db', '.sqlite', '.sqlite3', '.key', '.pem', '.p12', '.pfx',
                    '.mp4', '.wav', '.mp3', '.webm', '.zip', '.tar', '.gz', '.log',
                    '.pyc', '.exe', '.dll'}
PATTERNS = {
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider-key': re.compile(r'\b(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{30,})\b'),
    'jwt': re.compile(r'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}'),
    'home-path': re.compile(r'[A-Za-z]:[\\/]Users[\\/][^\s\\/]+|' +
                            re.escape('/' + 'home' + '/') + r'[^\s/]+|' +
                            re.escape('/' + 'Users' + '/') + r'[^\s/]+'),
    'phone': re.compile(r'(?<!\d)1[3-9]\d{9}(?!\d)'),
}
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')
PUBLIC_SERVICE_LOGINS = {'qr@a.pinggy.io'}  # Public SSH tunnel protocol login.
PUBLIC_CONTACT_EMAIL = 'changkaiyan@live.com'  # Explicitly approved by the maintainer for publication.
PUBLIC_CONTACT_PATHS = {'README.md', 'SECURITY.md', 'NOTICE', 'scripts/release_audit.py'}
IPV4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
LITERAL = re.compile(r'''(?i)(?:password|secret|access[_-]?token|api[_-]?key)["']?\s*[=:]\s*["']([^"'\n]{12,})["']''')
ENV_LITERAL = re.compile(r'(?i)^\s*[A-Z_]*(?:PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY)\s*=\s*([^\s#]{12,})\s*$')
PUBLIC_CONSTANTS = {'PlgvMymc7f3tQnJ6'}  # Provider protocol identifier, not an account credential.
# Visually reviewed fictional demo screenshots. Any replacement requires review again.
REVIEWED_BINARY_HASHES = {
    'docs/images/demo-meeting.jpg': 'a35000355469ba225d42a4ef54c34e7c737a21fb8ddafd32e0aea8321d8208b5',
    'docs/images/demo-dashboard.jpg': '90f9bd4b2ff66b0f2ed954a79117e93ac45514662b0746d1ada63a1b8ac49864',
}


def strip_png_metadata(data):
    """Remove metadata chunks only; preserve compressed pixels byte for byte."""
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Invalid PNG signature')
    output, offset = bytearray(data[:8]), 8
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError('Truncated PNG chunk')
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        end = offset + length + 12
        if end > len(data):
            raise ValueError('Truncated PNG data')
        if data[offset + 4:offset + 8] not in {b'tEXt', b'iTXt', b'zTXt', b'eXIf'}:
            output.extend(data[offset:end])
        offset = end
    return bytes(output)


def source_paths(root):
    result = subprocess.run(
        ['git', '-c', f'safe.directory={root.as_posix()}', 'ls-files', '-co',
         '--exclude-standard', '-z'], cwd=root, check=True, capture_output=True)
    return sorted({name for name in result.stdout.decode('utf-8').split('\0')
                   if name and ((root / name).is_file() or (root / name).is_symlink())})


def audit_paths(root, paths):
    findings = []
    for name in sorted(set(paths)):
        relative = PurePosixPath(name.replace('\\', '/'))
        path = root / name
        def flag(rule, line=0):
            findings.append({'path': name, 'line': line, 'rule': rule})
        if relative.is_absolute() or '..' in relative.parts or ':' in relative.parts[0]:
            flag('unsafe-path')
            continue
        if (PRIVATE_PARTS.intersection(relative.parts) or
                relative.suffix.lower() in PRIVATE_SUFFIXES or
                (relative.name.startswith('.env') and relative.name != '.env.example') or
                relative.name == 'livekit-keys.yaml'):
            flag('private-file')
            continue
        if path.is_symlink():
            flag('symlink')
            continue
        if not path.resolve().is_relative_to(root.resolve()):
            flag('unsafe-path')
            continue
        if not path.is_file():  # Deleted tracked files are not part of a release.
            continue
        data = path.read_bytes()
        if relative.suffix.lower() in {'.png', '.ico'}:
            if any(marker in data for marker in (b'tEXt', b'iTXt', b'zTXt', b'eXIf')):
                flag('image-metadata')
            continue
        try:
            content = data.decode('utf-8-sig')
        except UnicodeDecodeError:
            if hashlib.sha256(data).hexdigest() != REVIEWED_BINARY_HASHES.get(relative.as_posix()):
                flag('unreviewed-binary')
            continue
        synthetic = relative.name.startswith('test') or 'tests' in relative.parts
        for line_number, line in enumerate(content.splitlines(), 1):
            for rule, pattern in PATTERNS.items():
                if pattern.search(line):
                    flag(rule, line_number)
            for match in EMAIL.finditer(line):
                if match.group() in PUBLIC_SERVICE_LOGINS:
                    continue
                if match.group() == PUBLIC_CONTACT_EMAIL and relative.as_posix() in PUBLIC_CONTACT_PATHS:
                    continue
                domain = match.group(1).lower()
                if not (domain in {'example.com', 'example.org', 'example.net'} or
                        domain == 'example.test' or domain.endswith(('.invalid', '.example'))):
                    flag('email', line_number)
            for match in IPV4.finditer(line):
                try:
                    address = ipaddress.ip_address(match.group())
                except ValueError:
                    continue
                if (address.is_private and not address.is_loopback and
                        not address.is_unspecified and
                        not any(address in ipaddress.ip_network(block) for block in
                                ('192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24'))):
                    flag('private-ip', line_number)
            if not synthetic:
                for match in list(LITERAL.finditer(line)) + list(ENV_LITERAL.finditer(line)):
                    value = match.group(1)
                    if (value not in PUBLIC_CONSTANTS and
                            re.fullmatch(r'[A-Za-z0-9_+/=!.@-]+', value) and
                            not value.startswith(('replace-', 'example-', 'your-', 'test-'))):
                        flag('credential-literal', line_number)
    return findings


def export_release(root, paths, output):
    findings = audit_paths(root, paths)
    if findings:
        raise ValueError('Release blocked: fix audit findings before exporting.')
    output = Path(output)
    if output.exists():
        raise ValueError('Output already exists; choose a new release filename.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, 'x', compression=ZIP_DEFLATED) as archive:
        for name in sorted(set(paths)):
            path = root / name
            if path.is_file():
                archive.write(path, 'vibemeeting/' + name.replace('\\', '/'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Create an audited ZIP without Git history.')
    parser.add_argument('--strip-png-metadata', action='store_true', help='Remove PNG metadata without changing pixels.')
    args = parser.parse_args()
    paths = source_paths(ROOT)
    if args.strip_png_metadata:
        for name in paths:
            if name.lower().endswith('.png'):
                path = ROOT / name
                if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
                    continue
                original = path.read_bytes()
                cleaned = strip_png_metadata(original)
                if cleaned != original:
                    path.write_bytes(cleaned)
    findings = audit_paths(ROOT, paths)
    print(json.dumps({'files': sum((ROOT / name).is_file() for name in paths),
                      'findings': findings}, ensure_ascii=True, indent=2))
    if findings:
        return 1
    if args.output:
        export_release(ROOT, paths, args.output)
        print('Source ZIP exported without Git history or local runtime data.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
