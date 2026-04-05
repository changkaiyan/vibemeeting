#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_PROJECT_DIR="$ROOT_DIR/flutter_dashboard"
BUILD_OUTPUT_DIR="$ROOT_DIR/artifacts/flutter_dashboard_web"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is not installed or not on PATH" >&2
  exit 1
fi

cd "$FLUTTER_PROJECT_DIR"
flutter pub get
flutter build web

rm -rf "$BUILD_OUTPUT_DIR"
mkdir -p "$BUILD_OUTPUT_DIR"
cp -R "$FLUTTER_PROJECT_DIR/build/web/." "$BUILD_OUTPUT_DIR/"

echo "Flutter dashboard build synced to $BUILD_OUTPUT_DIR"
