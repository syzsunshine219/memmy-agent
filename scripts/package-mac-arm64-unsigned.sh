#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export MEMMY_SKIP_CODESIGN=1
bash "$ROOT_DIR/scripts/package-mac-dmg.sh" --arm64 "$@"
