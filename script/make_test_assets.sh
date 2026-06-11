#!/usr/bin/env bash
# Regenerate TestAssets/ (gitignored) from committed sources.
# TestAssets/rickroll.mov: face+body+hands motion clip used to iterate on
# landmark tracking with the app's Movie source (Source: Movie → Open Movie…).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/TestAssets"
swift "$ROOT_DIR/script/webp2mov.swift" "$ROOT_DIR/notes/rickroll.webp" "$ROOT_DIR/TestAssets/rickroll.mov"
