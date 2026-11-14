#!/usr/bin/env bash
# Compatibility shim: the Codex wave is super-board-lane-wave.sh --backend codex.
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-lane-wave.sh" --backend codex "$@"
