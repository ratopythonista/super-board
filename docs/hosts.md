# Agent hosts

super-board runs inside an agent host: the CLI whose session types `/super-board run`.
`scripts/super-board-host.sh` (installed as `.claude/bin/super-board-host.sh`) names it.

| Host value | Tested version | Start a run | Sign-in | Gaps |
|---|---|---|---|---|
| `claude` | Claude Code 2.1.302 | `/super-board run` (Workflow backend) | `claude` then `/login`; `gh auth login` | None. The reference host. |
| `codex` | codex-cli 0.160.0 | `/super-board run` inside Codex runs as `--codex`; from Claude, `/super-board run --codex` | `codex login`; `gh auth login` | No Workflow tool, so every lane is headless `codex exec`. Review runs only with explicit `--codex` (a host-switched plain `run` counts). No Claude usage guard. |
| `opencode` | OpenCode v2.0.22 | Not supported yet: the run halts with a host-selection request | `opencode auth login`; `gh auth login` | No OpenCode lane backend yet. `permission.external_directory: deny` is not enforced in v2.0.22 (`patch` still writes outside the repo), so OpenCode runs stay attended-only once a backend lands. |
| `omp` | omp 18.18.5 | `/super-board run --omp` (from OMP or any shell). A host-switched plain `run` counts as `--omp`. | `omp login`; `gh auth login` | No Workflow tool, so every lane is headless `omp -p`. Review runs only with explicit `--omp`; the run loads `.omp/extensions/super-board-guards.ts`. No Claude usage guard; per-lane `--max-time`/`--max-cost` replace it. |

Every host also needs `gh`, `jq`, bash 3.2+ and Python 3.9+.

## How the host is picked

`super-board-host.sh [--config <config.json>]` prints one value. First match wins:

1. `SUPER_BOARD_HOST=claude|codex|opencode|omp`, the manual override. Any other value exits 64.
2. `OMPCODE`, `PI_CODING_AGENT_DIR` or `OMP_PROFILE` → `omp`. OMP also exports
   `CLAUDECODE=1`, so its own sign is checked first.
3. `CODEX_THREAD_ID` or `CODEX_SESSION_ID` → `codex`.
4. `OPENCODE=1` → `opencode`. Checked before `CLAUDECODE`, which leaks into an OpenCode
   session started from Claude Code. `AGENT=1` is ignored: other tools set it too.
5. `CLAUDECODE` → `claude`.
6. The board config's top-level `host` key, when `--config` is given.
7. Nothing matched: empty stdout, a hint on stderr, exit 65. The run halts and asks for a
   host. It never guesses Claude.

A live env sign beats the saved config, so a Codex lane started from a Claude-configured
board still answers `codex`.

Onboard always writes `host` into `.claude/super-board/configs/<slug>.json`.
`super-board-setup.py fix` adds a missing one from `--host`; `check` flags any other value.

## Evidence

- Codex: env of `codex exec -s read-only`, 2026-10-04 (recorded in the script header).
- OpenCode: env diff of an `opencode run` shell, 2026-10-19: `OPENCODE=1`,
  `OPENCODE_SESSION_ID`, `OPENCODE_TERMINAL=1`, `AGENT=1`.
- OMP: `omp -p` shells, 2026-11-09 on 18.18.5: `OMPCODE=1` and `CLAUDECODE=1`;
  `PI_CODING_AGENT_DIR` names the active agent directory. `OMP_PROFILE` is accepted
  for named profiles.

## OMP lanes

`super-board-lane.sh --backend omp` (or `super-board-omp-lane.sh`, and wave via
`super-board-lane-wave.sh --backend omp` / `super-board-omp-wave.sh`) runs one
`omp -p --mode json` per lane:

```bash
omp -p --mode json --no-title --auto-approve \
  --tools read,bash,edit,write,grep,glob,web_search[,task] \
  --config <run>/roles.yml --model @<role> \
  --max-time <cap> --max-cost <cap> --no-extensions \
  -e <repo>/.omp/extensions/super-board-guards.ts \
  --session-dir <run>/sessions "<prompt>"
```

- `--model` is a `modelRoles` alias: the ladder picks `@easy`/`@medium`/`@hard`,
  Review always uses `@review`. `--omp=<model|@role>` pins every lane and is the
  explicit Review opt-in. `omp.model` pins too.
- The lane writes its result JSON to a private temp file named in the prompt;
  the wrapper validates it with the same schema as Codex (bare JSON, a fenced JSON block, or the first JSON object in prose), then scans the NDJSON assistant
  messages newest first, so an aborted `task` subagent's last text is skipped
  instead of inherited. A rejected payload is kept at
  `.claude/super-board/rejected/lane-result-rejected-<lane>-<card>.{json,txt}`,
  and the failure names that path and every schema path that missed. Anything
  else fails closed.
- `--max-cost` exit 3 becomes `status=halted`/`cost-cap`; a `--max-time` deadline
  becomes `halted`/`time-cap`. Card, claim, worktree and PR are preserved.
- `--no-extensions` plus an explicit `-e` keeps user extensions out. The guard
  extension calls the six Python hooks unchanged and narrows `task` subagents to
  `read,bash,grep,glob`: a child session does not inherit the parent's `--tools`.
- The installer links `.omp/extensions/super-board-guards.ts`; a lane refuses to
  start when the extension is missing rather than running unguarded.
