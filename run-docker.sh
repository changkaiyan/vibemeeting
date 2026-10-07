#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"
command -v docker >/dev/null 2>&1 || { echo 'Install Docker with Compose first.' >&2; exit 1; }
docker info --format '{{.ServerVersion}}'
docker compose version
compose=(docker compose --project-name smart-meeting --env-file .runtime/docker.env -f compose.yaml)
case "${1:-}" in
  --stop) "${compose[@]}" down ;;
  --logs) "${compose[@]}" logs --follow ;;
  *)
    docker run --rm --user "$(id -u):$(id -g)" --mount "type=bind,source=$root,target=/workspace" --workdir /workspace \
      python:3.12-slim-bookworm python scripts/launcher.py docker-config --host-root "$root" "$@"
    "${compose[@]}" up --build --force-recreate --detach --wait --wait-timeout 180
    docker run --rm --user "$(id -u):$(id -g)" --mount "type=bind,source=$root,target=/workspace" --workdir /workspace \
      python:3.12-slim-bookworm python scripts/launcher.py docker-info
    ;;
esac
