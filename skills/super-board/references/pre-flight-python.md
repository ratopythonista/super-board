# Pre-flight — Python (Django + HTMX)

The lanes read this file before touching a card. It names the stack, the exact
commands and the paths a worker must not change. Onboarding writes it once when
`docs/super-board/` has no Python pre-flight; after that it belongs to the repo.

## Stack

- Python 3.12 in `.python-version`, `uv` with a committed `uv.lock`.
- Django 6.1, `django-htmx`, Tailwind standalone (committed `app.css`) and Granian.
- src-layout: package under `src/<package>/`, tests under `tests/`.
- `CODING_STANDARDS.md` is managed by the pack; read it before judging a diff.

## Commands

Run from the stack root (`stack.root` in the config; `python/` in the example config):

```bash
uv sync --frozen                       # never resolves a new lock
bash scripts/check.sh                  # lint, format, types, size and coverage
uv run python -m pytest -m e2e         # QA only: Granian on a free port
bash scripts/fetch_tailwind.sh         # once per machine
bash scripts/build_css.sh              # after a template/class change
bash scripts/serve.sh                  # http://127.0.0.1:8000
```

`check.sh` is the gate: `ruff check`, `ruff format --check`, `ty check src`,
`size_check.py` (warn at 200, fail at 250) and `pytest --cov` with a 90%
line+branch floor. The board's `verify_commands` are `uv sync --frozen` plus
`bash scripts/check.sh`; they run in Build and again at the merge gate.

## Boundaries

- NEVER read, print or source `.env`; key names only, through
  `.claude/bin/super-board-env-check.sh`.
- NEVER hand-edit `uv.lock`; change `pyproject.toml` and run `uv lock`.
- NEVER edit `CODING_STANDARDS.md`, `scripts/check.sh`, `scripts/size_check.py`, `.github/workflows/ci.yml`,
  `.github/dependabot.yml`, `scripts/audit.sh` or `scripts/release.sh` in place: they are managed by the pack.
  Fix the skill template instead.
- NEVER compile CSS by editing `app.css` by hand; change `input.css` or the
  template and run `build_css.sh`.
- Migrations follow `migrations.allowed_envs`; a destructive schema change is
  always a human gate.
- No credentials, no deploy and no cloud commands in a lane.

## Environment

- `gh` authenticated with `project` and `repo` scopes.
- `uv`, `python3` and `jq` on PATH; Playwright Chromium cached for QA.
- Tailwind standalone in `.tools/` (the fetch script pins the version).
- No production signal by default; `base_branch` and `merge_policy` come from
  the board config, not from this file.
