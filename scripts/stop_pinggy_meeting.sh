#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8012}"
RUN_DIR="${ROOT_DIR}/.runlogs/meeting-pinggy"
DJANGO_PID_FILE="${RUN_DIR}/django-${PORT}.pid"
PINGGY_PID_FILE="${RUN_DIR}/pinggy-${PORT}.pid"
DJANGO_SESSION="meeting-django-${PORT}"
PINGGY_SESSION="meeting-pinggy-${PORT}"

stop_from_pid_file() {
  local pid_file="$1"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
}

stop_from_pid_file "${PINGGY_PID_FILE}"
stop_from_pid_file "${DJANGO_PID_FILE}"
pkill -f "manage.py runserver 0.0.0.0:${PORT} --noreload" 2>/dev/null || true
pkill -f "ssh -p 443 .*localhost:${PORT}.*a.pinggy.io" 2>/dev/null || true
tmux kill-session -t "${PINGGY_SESSION}" 2>/dev/null || true
tmux kill-session -t "${DJANGO_SESSION}" 2>/dev/null || true

echo "Stopped meeting tunnel processes for port ${PORT}"
