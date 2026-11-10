#!/usr/bin/env bash
# super-board-host.sh — which agent host is this shell inside: `claude`, `codex`, `opencode`
# or `omp`.
#
# WHY. `/super-board run` launched from a Codex or OMP session has no Claude Workflow tool, so
# the workflow backend cannot start. The orchestrator checks its own tool list first; this is
# the check a script can make, and the tie-breaker when the tool list is unclear. A shell with
# no known sign gets no answer (exit 65): guessing Claude there starts the wrong backend.
#
# THE SIGNALS.
# - OMP sets OMPCODE=1 and also CLAUDECODE=1 (it identifies as Claude for imported tooling),
#   so its own sign must be checked before CLAUDECODE. PI_CODING_AGENT_DIR names the active
#   agent directory and OMP_PROFILE a named profile; both are set by OMP shells and profiles.
#   Observed 2026-11-09 on omp 18.18.0/18.18.5 (env of `omp -p` shells).
# - Codex CLI sets CODEX_THREAD_ID (and CODEX_SESSION_ID, the same value) in every shell it
#   runs. Observed 2026-10-04 on codex-cli 0.160.0 with `codex exec -s read-only`:
#   CODEX_THREAD_ID, CODEX_SESSION_ID, CODEX_VERSION, CODEX_SANDBOX=seatbelt, CODEX_CI=1.
#   Not used: CODEX_HOME (people export it in their own profile), CODEX_SANDBOX (absent when
#   the sandbox is off). A Codex lane started from a Claude session also carries CLAUDECODE;
#   the Codex ids still win there, because the innermost host is the one running this shell.
# - OpenCode sets OPENCODE=1 (plus OPENCODE_SESSION_ID, OPENCODE_TERMINAL=1, AGENT=1) in the
#   shells it runs. Observed 2026-10-19 on opencode v2.0.22 (env diff of a `run` shell).
#   Checked before CLAUDECODE, which leaks into OpenCode started from a Claude session.
#   Not used: AGENT=1 (a generic name other tools set too).
# - Claude Code sets CLAUDECODE=1.
#
# ORDER. SUPER_BOARD_HOST, OMP signs, Codex ids, OPENCODE, CLAUDECODE, then the config's
# top-level `host` key (--config <file>), else exit 65. A live env sign beats the saved config.
#
# Usage: super-board-host.sh [--config <config.json>]
#        prints `claude`, `codex`, `opencode` or `omp`, exit 0
#        exit 65   no sign: nothing on stdout, how to choose on stderr
#        exit 64   SUPER_BOARD_HOST or config `host` is not one of the four
# SUPER_BOARD_HOST=claude|codex|opencode|omp forces the answer (tests, or a host the check
# misreads).
set -euo pipefail

config=
case "${1:-}" in
  --config) config=${2:-} ;;
  '') ;;
  *) echo "usage: super-board-host.sh [--config <config.json>]" >&2; exit 64 ;;
esac

case "${SUPER_BOARD_HOST:-}" in
  claude|codex|opencode|omp) echo "$SUPER_BOARD_HOST"; exit 0 ;;
  '') ;;
  *) echo "super-board-host.sh: SUPER_BOARD_HOST must be claude, codex, opencode or omp" >&2; exit 64 ;;
esac

if [ -n "${OMPCODE:-}" ] || [ -n "${PI_CODING_AGENT_DIR:-}" ] || [ -n "${OMP_PROFILE:-}" ]; then
  echo omp
elif [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
  echo codex
elif [ -n "${OPENCODE:-}" ]; then
  echo opencode
elif [ -n "${CLAUDECODE:-}" ]; then
  echo claude
elif saved=$( [ -f "$config" ] && jq -r '.host // empty' "$config" 2>/dev/null ) && [ -n "$saved" ]; then
  case "$saved" in
    claude|codex|opencode|omp) echo "$saved" ;;
    *) echo "super-board-host.sh: config host must be claude, codex, opencode or omp, got '$saved'" >&2; exit 64 ;;
  esac
else
  echo "super-board-host.sh: unknown agent host. Pick one: SUPER_BOARD_HOST=claude|codex|opencode|omp, or set \"host\" in the board config" >&2
  exit 65
fi
