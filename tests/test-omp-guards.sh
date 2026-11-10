#!/usr/bin/env bash
# Offline test for extensions/super-board-guards.ts. Node strips the TS types;
# the real hooks/*.py are copied into an isolated repo root.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo"
git init -q "$T/repo"
SB_GUARD_ROOT="$T/repo" node --experimental-strip-types "$KIT/tests/test-omp-guards.mjs"
