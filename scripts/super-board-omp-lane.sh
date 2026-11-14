#!/usr/bin/env bash
# Compatibility shim: the OMP lane is super-board-lane.sh --backend omp (same flags).
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-lane.sh" --backend omp "$@"
