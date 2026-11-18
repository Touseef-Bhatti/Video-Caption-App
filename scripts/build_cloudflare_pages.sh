#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${API_BASE_URL:-}" ]]; then
  echo "API_BASE_URL must be set in the Cloudflare Pages environment variables." >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  flutter_root="${FLUTTER_ROOT:-/tmp/flutter}"
  if [[ ! -x "$flutter_root/bin/flutter" ]]; then
    git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$flutter_root"
  fi
  export PATH="$flutter_root/bin:$PATH"
fi

flutter --version
cd frontend
flutter pub get
flutter build web --release --dart-define="API_BASE_URL=${API_BASE_URL}"
