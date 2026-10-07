#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$root/.venv/bin/python" ]]; then
  python="$root/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  python=python3
else
  echo 'Install Python 3.10+ (including venv) and Git. Docker is required for recording.' >&2
  exit 1
fi
exec "$python" "$root/scripts/launcher.py" local "$@"
