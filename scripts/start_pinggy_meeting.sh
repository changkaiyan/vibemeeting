#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8012}"
ROOM_NAME="${ROOM_NAME:-room-demo01}"
RUN_DIR="${ROOT_DIR}/.runlogs/meeting-pinggy"
DJANGO_LOG="${RUN_DIR}/django-${PORT}.log"
PINGGY_LOG="${RUN_DIR}/pinggy-${PORT}.log"
DJANGO_PID_FILE="${RUN_DIR}/django-${PORT}.pid"
PINGGY_PID_FILE="${RUN_DIR}/pinggy-${PORT}.pid"
PUBLIC_URL_FILE="${RUN_DIR}/public_url.txt"
DJANGO_SESSION="meeting-django-${PORT}"
PINGGY_SESSION="meeting-pinggy-${PORT}"

mkdir -p "${RUN_DIR}"

cleanup_stale_process() {
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

cleanup_stale_process "${DJANGO_PID_FILE}"
cleanup_stale_process "${PINGGY_PID_FILE}"
pkill -f "manage.py runserver 0.0.0.0:${PORT} --noreload" 2>/dev/null || true
pkill -f "ssh -p 443 .*localhost:${PORT}.*a.pinggy.io" 2>/dev/null || true
tmux kill-session -t "${DJANGO_SESSION}" 2>/dev/null || true
tmux kill-session -t "${PINGGY_SESSION}" 2>/dev/null || true

cd "${ROOT_DIR}"

: > "${DJANGO_LOG}"
: > "${PINGGY_LOG}"
rm -f "${PUBLIC_URL_FILE}"

tmux new-session -d -s "${DJANGO_SESSION}" \
  "cd '${ROOT_DIR}' && \
   export PYTHONUNBUFFERED=1 && \
   export ALLOWED_HOSTS='127.0.0.1,localhost,*' && \
   export CSRF_TRUSTED_ORIGINS='https://*.pinggy.link,https://*.a.free.pinggy.link,https://*.pinggy.io,https://*.run.pinggy.link,https://*.run.pinggy-free.link' && \
   exec '${ROOT_DIR}/.venv/bin/python' manage.py runserver '0.0.0.0:${PORT}' --noreload >> '${DJANGO_LOG}' 2>&1"
tmux list-panes -t "${DJANGO_SESSION}" -F "#{pane_pid}" | head -n 1 > "${DJANGO_PID_FILE}"

for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
  echo "Django failed to start. See ${DJANGO_LOG}" >&2
  exit 1
fi

tmux new-session -d -s "${PINGGY_SESSION}" \
  "exec ssh \
   -p 443 \
   -o StrictHostKeyChecking=no \
   -o ServerAliveInterval=30 \
   -o ExitOnForwardFailure=yes \
   -R0:localhost:${PORT} \
   qr@a.pinggy.io >> '${PINGGY_LOG}' 2>&1"
tmux list-panes -t "${PINGGY_SESSION}" -F "#{pane_pid}" | head -n 1 > "${PINGGY_PID_FILE}"

for _ in $(seq 1 30); do
  if grep -Eo 'https://[^[:space:]]+' "${PINGGY_LOG}" | tail -n 1 > "${PUBLIC_URL_FILE}.tmp"; then
    if [[ -s "${PUBLIC_URL_FILE}.tmp" ]]; then
      mv "${PUBLIC_URL_FILE}.tmp" "${PUBLIC_URL_FILE}"
      break
    fi
  fi
  sleep 1
done
rm -f "${PUBLIC_URL_FILE}.tmp"

if [[ ! -f "${PUBLIC_URL_FILE}" ]]; then
  echo "Pinggy failed to allocate a public URL. See ${PINGGY_LOG}" >&2
  exit 1
fi

PUBLIC_URL="$(cat "${PUBLIC_URL_FILE}")"
SHARE_CODE="$("${ROOT_DIR}/.venv/bin/python" manage.py shell -c "from conference.share import build_meeting_share_code; print(build_meeting_share_code('${ROOM_NAME}'))" | tail -n 1)"

cat <<EOF
Django PID: $(cat "${DJANGO_PID_FILE}")
Pinggy PID: $(cat "${PINGGY_PID_FILE}")
Django log: ${DJANGO_LOG}
Pinggy log: ${PINGGY_LOG}
Public base URL: ${PUBLIC_URL}
Meeting URL: ${PUBLIC_URL}/m/${SHARE_CODE}
EOF
