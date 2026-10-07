#!/usr/bin/env sh
set -eu
mkdir -p /data /recordings
python manage.py migrate --noinput
python manage.py bootstrap_admin
python manage.py collectstatic --noinput
exec python -m uvicorn smart_meeting.asgi:application --host 0.0.0.0 --port 8000
