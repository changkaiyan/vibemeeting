"""Reject publishing from branches or a tag that does not match package version."""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from vibemeeting import __version__


def validate_release_ref(ref, version):
    if ref != f'refs/tags/v{version}':
        raise ValueError(f'Publishing requires the exact tag v{version}, matching the package version.')
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', required=True)
    args = parser.parse_args()
    try:
        metadata = (ROOT / 'pyproject.toml').read_text(encoding='utf-8')
        match = re.search(r'(?ms)^\[project\].*?^version = "([^"]+)"', metadata)
        if not match or match.group(1) != __version__:
            raise ValueError('pyproject.toml and vibemeeting.__version__ must match.')
        print('Release version validated: ' + validate_release_ref(args.ref, __version__))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
