#!/bin/sh
# One-command build: run the full test suite, then produce the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift test
./scripts/make-app.sh
echo "All tests passed. App ready: build/mac-midi-router.app"
