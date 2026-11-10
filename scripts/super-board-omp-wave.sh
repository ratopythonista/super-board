#!/usr/bin/env bash
# Compatibility shim: the OMP wave is super-board-lane-wave.sh --backend omp.
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-lane-wave.sh" --backend omp "$@"
