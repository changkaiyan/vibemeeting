FROM debian:bookworm-slim AS frontend
ARG FLUTTER_VERSION=3.41.6
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /frontend
COPY flutter_app/pubspec.yaml flutter_app/pubspec.lock ./
RUN flutter pub get
COPY flutter_app/lib ./lib
COPY flutter_app/web ./web
RUN flutter build web --release --no-pub --no-wasm-dry-run

FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY manage.py ./
COPY smart_meeting ./smart_meeting
COPY conference ./conference
COPY app/templates ./app/templates
COPY app/static/meeting-room.js app/static/style.css ./app/static/
COPY scripts/container_start.sh ./scripts/container_start.sh
COPY --from=frontend /frontend/build/web ./artifacts/flutter_app_web
EXPOSE 8000
CMD ["sh", "scripts/container_start.sh"]
