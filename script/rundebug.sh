#!/usr/bin/env bash
set -euo pipefail

# Kept as a compatibility name for existing muscle memory. It intentionally
# delegates to run.sh instead of guessing at a DerivedData product.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/script/run.sh" "$@"
