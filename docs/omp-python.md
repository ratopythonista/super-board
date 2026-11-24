# OMP host + Python project: install and configure

[hosts.md](hosts.md) says what the `omp` host is and where it differs from Claude Code. This page is the
install path for a fork and the board config shape that makes the OMP lanes useful in a Python project.

Nothing here is upstream-specific: the pack is MIT, the fork only adds the OMP backend and the guard extension.

## Prerequisites

| Tool | Why | Check |
|---|---|---|
| `gh` | board, issues, PRs, merge gate | `gh auth status` |
| `jq` | every script parses board and run state with it | `jq --version` |
| `python3` ≥ 3.9 | installer, setup check, merge policy | `python3 --version` |
| `bash` ≥ 3.2 | scripts are written for stock macOS bash | `bash --version` |
| OMP ≥ 18.18.5 | the host that runs the lanes | `omp --version`, `omp login` |
| `uv` + `ruff` | the Python project's verify commands | `uv --version` |
| `npx` | helper skills (`mattpocock/skills`) and the published skill | `npx --version` |

`node` is only needed for `npx`; the OMP backend itself does not use it.

## Install from the fork

```bash
cd /path/to/project
curl -fsSL https://raw.githubusercontent.com/ratopythonista/super-board/main/get.sh \
  | SUPER_BOARD_REPO=ratopythonista/super-board bash -s -- --ref v3.5.1-omp.1 --hosts=omp
```

- `SUPER_BOARD_REPO` makes `get.sh` fetch the fork instead of `EricTechPro/super-board`. It must reach
  `bash`, not `curl`: prefixing only the `curl` call leaves the installer with the upstream default.
- `--ref` pins the release tag (or a branch, e.g. `main` for the fork's tip). Omit it and `get.sh` uses the
  fork's latest release, which is this same tag. The older `v3.5.0-omp.1` tag has no GitHub Release, so it
  only works as an explicit `--ref`.
- `--hosts=omp` links `.omp/` as well as `.claude/`. Use the **`=` form**: `get.sh` passes unknown flags
  through to `install.sh` but a bare `--hosts omp` would read `omp` as a second target folder.
- Add `--protect-main` to block direct and force pushes to the base branch, and `--no-hooks` to leave
  `.claude/settings.json` untouched.

From a checkout you already have:

```bash
./install.sh --hosts=omp /path/to/project
```

### What lands where

| Path | Contents |
|---|---|
| `.agents/` | canonical install: `skills/`, `bin/`, `workflows/`, `hooks/` |
| `.claude/` | one link per skill, script, workflow and hook; `settings.json` merged once (backed up) |
| `.omp/` | the same links, plus `extensions/super-board-guards.ts` |
| `.claude/super-board/` | created by `onboard`: configs, worktrees, ledgers, rejected lane diagnostics |
| `AGENTS.md` | the managed block (pack version) is written by `onboard`; a re-install only refreshes it |

On a Python board, `onboard` also materializes the pack at `stack.root`: the six skills under
`.agents/skills/`, then `CODING_STANDARDS.md`, `scripts/check.sh`, `scripts/size_check.py`, the delivery
files (`.github/workflows/ci.yml`, `.github/dependabot.yml`, `scripts/audit.sh`, `scripts/release.sh`,
`LICENSE`) and `docs/super-board/pre-flight-python.md` (the pre-flight only when missing). Drift is
`python-scaffold --check`, never an edit in place.

Verify the result before trusting it:

```bash
python3 .claude/bin/super-board-setup.py check --root . --host omp
```

A fresh install is **not green yet**: it reports two required skills missing — `testing-strategy`
(`anthropics/knowledge-work-plugins`) and `verification-before-completion` (`obra/superpowers`). No installer
can guess those two upstreams, so install them by URL and check again:

```bash
npx skills add https://github.com/anthropics/knowledge-work-plugins/tree/main/engineering/skills/testing-strategy
npx skills add https://github.com/obra/superpowers/tree/main/skills/verification-before-completion
```

`green: true` means the skills, the scripts and the host surface agree. The TS-era helpers (`vitest`,
`playwright-best-practices`) come back as `skipped`, not missing: a Python project does not need them.
`configs` stays empty until `/super-board onboard` writes one — and `fix` adds a missing `host` key.

## Configure the board

`/super-board onboard` writes `.claude/super-board/configs/<slug>.json`. It asks the questions; the file is
what the scripts read. On a Python repo it also installs the six pack skills, materializes
`CODING_STANDARDS.md`, the gate and the delivery files with `python-scaffold --gate-only` +
`--delivery-only`, and writes the pre-flight once.
A Python board differs from the default in these places:

```jsonc
{
  "project": { "owner": "you", "title": "your-project", "number": 5 },
  "host": "omp",
  "stack": { "name": "python", "profile": "web", "root": "python" },
  "base_branch": "main",
  "columns": ["Backlog", "Ready", "Building", "QA", "Review", "Blocked", "Done"],
  "merge_policy": { "default": "auto" },
  "human_approves_merge": false,
  "verify_commands": [
    "cd python && uv sync --frozen",
    "cd python && bash scripts/check.sh"
  ],
  "paths": { "pre_flight_md": "docs/super-board/pre-flight-python.md" },
  "omp": {
    "modelRoles": {
      "classify": ["provider/model:low"],
      "easy":     ["provider/model:low"],
      "medium":   ["provider/model:high"],
      "hard":     ["provider/model:max"],
      "review":   ["provider/model:max"],
      "task":     ["provider/model:max"]
    },
    "retry": { "fallbackChains": { "easy": ["provider/fallback:low"] } },
    "limits": {
      "classify": { "max_cost": 0.05, "max_time": "3m" },
      "build":    { "max_cost": 0.5,  "max_time": "30m" },
      "qa":       { "max_cost": 0.3,  "max_time": "20m" },
      "review":   { "max_cost": 0.75, "max_time": "30m" }
    }
  }
}
```

- **`stack` selects the pack.** `{"name": "python", "profile": "web", "root": "python"}`. Onboarding writes it
  from `pyproject.toml` + `uv.lock` (root, or one subdirectory) and the resolver requires the Python skills per
  lane. `root` is `"."` when the project is at the repo root; the managed files and `CODING_STANDARDS.md` live
  there.
- **`verify_commands` must be non-empty.** The merge gate refuses to merge on faith; a missing list halts
  setup. These two run in Build and again at the gate, pinned to the reviewed commit; `check.sh` is the
  canonical gate (ruff, `ruff format --check`, `ty`, size-check and pytest with coverage).
- **E2E stays out of them.** Playwright is slow; it belongs to the QA lane, where the prompt can wait.
- **`worker_backend` is inert under OMP.** It is a Claude-era key (`workflow` vs `claude-p`); under OMP the
  host has no Workflow tool, so `--omp` alone selects the headless `omp -p` lanes. Leaving the key in a
  copied config does nothing.
- **`retry.fallbackChains` nests under `retry`.** A flat `fallbackChains` is ignored by OMP.
- **`limits` are flat per lane.** They replace Claude's usage guard: a cap ends the lane as `halted` and
  leaves the card, claim, worktree and PR where they are.
- **`paths.pre_flight_md`** is the repo pre-flight the lanes read first — name the stack, the commands and
  the paths they must not touch.

## Run a wave

```bash
/super-board run --omp          # router @classify · easy → @medium · medium and hard → @hard
/super-board run --omp --low    # easy → @easy · medium → @medium · hard → @hard
/super-board run --omp --high   # router @medium · everything → @hard
```

Plain `run` inside an OMP session counts as `--omp`. Review only runs with the explicit flag (or a
host-switched plain run): it is the lane that merges. The lane command, the role table and what the caps end are
in [The OMP lane](omp-lane.md).

## Python pack skills

The six pack skills come from `ratopythonista/skills`. Onboarding installs them when the config has
`"stack": {"name": "python", …}` (step 1) and the resolver makes them mandatory per lane; installing by hand
is the same six URLs:

```bash
for s in python-standards python-scaffold python-verify python-testing python-web python-release; do
  npx -y skills@latest add "https://github.com/ratopythonista/skills/tree/main/skills/$s" -y
done
```

`pytest-fasthtml` is not part of the pack and stays out of a Django project. The resolver reads `stack.name`
from the active config (`--stack python` overrides it) and requires:

| Lane | Mandatory | Conditional, rechecked with `--require` |
| --- | --- | --- |
| Build | `python-standards`, `python-testing` | `python-scaffold`, `python-verify`, `python-web`, `python-release` |
| QA | `python-testing` | `python-verify`, `python-web`, `python-release` |
| Review | `python-standards` | `python-release` |

The scaffold owns the managed files at `stack.root`: `CODING_STANDARDS.md`, `scripts/check.sh`,
`scripts/size_check.py`, `.github/workflows/ci.yml`, `.github/dependabot.yml`, `scripts/audit.sh` and
`scripts/release.sh`, plus the one-shot MIT `LICENSE`. Onboarding materializes them with
`python-scaffold --gate-only` and `--delivery-only` (no second app skeleton) and writes
`[tool.pack-python]` once; drift is `scaffold.py --check`, not an edit in place.
A card may still name the profile explicitly:

```md
## Card

…

Skills: python-web, python-testing, python-verify
```

`Skills:` replaces the Build lane's default label row; the mandatory Python rows and the always-listed helpers
stay. The pack's contract is in
[`pack-python`](https://github.com/ratopythonista/skills/blob/main/pack.json), and
`CODING_STANDARDS.md` in the repo outranks every skill.
