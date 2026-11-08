#!/usr/bin/env bash
# Local typecheck without a Mac.
#
# The macOS-only parts of HermesKit (URLSessionWebSocketTask) are behind
# `#if canImport(Darwin)`, so the pure-Foundation targets build on Linux. SwiftUI
# targets cannot — they are only compiled by CI on macOS runners.
#
#   ./Tools/dev/typecheck.sh            # build + test every target that can build on Linux
#   ./Tools/dev/typecheck.sh HermesRender  # one target
set -euo pipefail

cd "$(dirname "$0")/../.."
TARGET="${1:-}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — this script relies on the swift:6.0-jammy image" >&2
  exit 1
fi

if [ -n "$TARGET" ]; then
  CMD="swift build --target $TARGET 2>&1 | tail -60"
else
  CMD="swift build --build-tests 2>&1 | tail -80 && swift test 2>&1 | tail -30"
fi

exec docker run --rm -v "$PWD:/src" -w /src swift:6.0-jammy bash -euo pipefail -c "$CMD"
