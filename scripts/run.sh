#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ALGORITHMS_REPO="${SORTING_SANDBOX_ALGORITHMS:-$ROOT/algorithms}"
PORT="${SORTING_SANDBOX_PORT:-8080}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --algorithms)
      ALGORITHMS_REPO="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --no-open)
      NO_OPEN=1
      shift
      ;;
    -h|--help)
      cat <<USAGE
Usage: ./run [--algorithms PATH] [--port PORT] [--no-open]

Defaults:
  algorithms: ./algorithms
  port:       8080

The algorithms directory may be its own nested Git repository. The outer
Sorting Sandbox repository ignores it completely.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter was not found in PATH." >&2
  exit 127
fi
if ! command -v dart >/dev/null 2>&1; then
  echo "dart was not found in PATH." >&2
  exit 127
fi
if [[ ! -d "$ALGORITHMS_REPO" ]]; then
  cat >&2 <<MSG
Algorithm repository not found: $ALGORITHMS_REPO

Clone the shared class repository into the ignored nested directory:

  git clone <class-repository-url> algorithms

For the bundled examples you can simply keep the included algorithms/ folder.
MSG
  exit 66
fi

cleanup() {
  if [[ -n "${WATCH_PID:-}" ]]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> Resolving application dependencies"
flutter pub get

echo "==> Preparing current class algorithms"
dart run tool/prepare_algorithms.dart \
  --repo "$ALGORITHMS_REPO" \
  --compile-worker

echo "==> Building the Flutter web application"
flutter build web --release

echo "==> Starting automatic algorithm watcher"
dart run tool/watch_algorithms.dart --repo "$ALGORITHMS_REPO" &
WATCH_PID=$!

OPEN_ARG=(--open)
if [[ "${NO_OPEN:-0}" == "1" ]]; then
  OPEN_ARG=()
fi

echo "==> Starting classroom server"
dart run tool/classroom_server.dart --port "$PORT" "${OPEN_ARG[@]}"
