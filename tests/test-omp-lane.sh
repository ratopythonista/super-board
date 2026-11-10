#!/usr/bin/env bash
# Stubbed OMP only: model roles/pinning, review consent, caps, allowlist, guard
# extension, result file + NDJSON fallback, wave routing/concurrency/halt/locks.
# No network. Every case runs through super-board-omp-lane.sh and
# super-board-lane.sh --backend omp where a lane is involved.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/.omp/extensions" "$T/home"
git init -q "$T/repo"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
printf 'export default function () {}\n' > "$T/repo/.omp/extensions/super-board-guards.ts"
export SUPER_BOARD_SKILLS_HOME="$T/home"
cat > "$T/bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
chmod +x "$T/bin/gh"
export SB_OMP_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cp "$KIT/tests/fixtures/fake_omp.py" "$T/bin/omp"
chmod +x "$T/bin/omp"
cd "$T/repo"
cat > "$T/config.json" <<'JSON'
{
  "verify_commands": ["git diff --check"],
  "omp": {
    "modelRoles": {
      "classify": ["fake/classify", "fake/classify-2"],
      "easy": ["fake/easy"],
      "medium": ["fake/medium"],
      "hard": ["fake/hard"],
      "review": ["fake/review"],
      "task": ["fake/task"]
    },
    "retry": {"fallbackChains": {"easy": ["fake/easy-2"], "review": [], "task": []}},
    "limits": {
      "classify": {"max_cost": 0.05, "max_time": "3m"},
      "build": {"max_cost": 0.5, "max_time": "30m"},
      "qa": {"max_cost": 0.3, "max_time": "20m"},
      "review": {"max_cost": 0.75, "max_time": "30m"}
    }
  }
}
JSON
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "$KIT/scripts/super-board-omp-lane.sh" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
lane_backend() { bash "$KIT/scripts/super-board-lane.sh" --backend omp --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
wave() { bash "$KIT/scripts/super-board-omp-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last() { tail -1 "$SB_OMP_TEST_LOG"; }
count() { wc -l < "$SB_OMP_TEST_LOG" | tr -d ' '; }
# Parse the recorded overlay as YAML: fallback chains must nest under retry.fallbackChains.
overlay_chains() { # expected fallbackChains JSON, label
  python3 - "$T/overlay.yml" "$1" "$2" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as stream:
    doc = yaml.safe_load(stream)
want, where = json.loads(sys.argv[2]), sys.argv[3]
retry = doc.get('retry')
got = retry.get('fallbackChains') if isinstance(retry, dict) else None
if got != want:
    sys.exit(f'{where}: retry.fallbackChains is {got!r}, want {want!r}')
PY
}

# Review needs the explicit --omp flag; nothing launches before that refusal.
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_OMP_TEST_LOG" ] || fail 'fallback review must refuse before OMP'
lane review --omp >"$T/out"
jq -e '.status == "advanced" and .column == "Done"' "$T/out" >/dev/null || fail 'explicit review allowed'
[ "$(last | jq -r '.model')" = '@review' ] || fail 'review must use @review'
[ "$(last | jq -r '.tools')" = 'read,bash,edit,write,grep,glob,web_search,task' ] || fail 'review allowlist needs task'
[ "$(last | jq -r '.env.SUPER_BOARD_RUN')" = 1 ] || fail 'SUPER_BOARD_RUN must reach the worker'
[ "$(last | jq -r '.env.CLAUDE_PROJECT_DIR')" = "$(pwd -P)" ] || fail 'CLAUDE_PROJECT_DIR must name the repo root'
[ -n "$(last | jq -r '.env.SUPER_BOARD_LANE_MODEL_FILE')" ] || fail 'the model evidence file must be exported'
grep -q -- '--no-extensions' "$SB_OMP_TEST_LOG" || fail 'user extensions must be disabled'
grep -q -- '-e' "$SB_OMP_TEST_LOG" || fail 'the guard extension must be explicit'
last | jq -e '.config | contains("modelRoles:") and contains("hard: \"fake/hard\"") and contains("review: []")' >/dev/null \
  || fail 'the overlay carries modelRoles and retry fallback chains'
last | jq -r '.config' > "$T/overlay.yml"
overlay_chains '{"easy":["fake/easy-2"],"review":[],"task":[]}' 'lane overlay'
last | jq -r '.args | map(tostring) | join(" ")' | grep -q -- '--max-cost 0.75 --max-time 30m' || fail 'review caps must be passed'
last | jq -r '.args | map(tostring) | join(" ")' | grep -q -- '--session-dir' || fail 'sessions need a private dir'
# No configured chains still parse as an object, never null.
jq 'del(.omp.retry)' "$T/config.json" > "$T/config-no-retry.json"
bash "$KIT/scripts/super-board-omp-lane.sh" --config "$T/config-no-retry.json" --card "$CARD" --lane review --omp >"$T/out"
last | jq -r '.config' > "$T/overlay.yml"
overlay_chains '{}' 'lane overlay without chains'

# The second entry point is the same backend.
: > "$SB_OMP_TEST_LOG"
lane_backend build --omp >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail '--backend omp build advances'
[ "$(last | jq -r '.tools')" = 'read,bash,edit,write,grep,glob,web_search' ] || fail 'build allowlist must omit task'
[ "$(last | jq -r '.args | map(tostring) | join(" ")' | grep -o -- '--max-cost [0-9.]*')" = '--max-cost 0.5' ] || fail 'build cap'

# Ladders map run tier x complexity to roles; an ungraded card takes @medium.
while read -r TIER GRADE WANT; do
  lane build --omp --tier "$TIER" ${GRADE:+--complexity "$GRADE"} >"$T/out"
  [ "$(last | jq -r '.model')" = "$WANT" ] || fail "ladder $TIER/$GRADE must pick $WANT, got $(last | jq -r '.model')"
done <<'CELLS'
medium low @medium
medium medium @hard
medium high @hard
low low @easy
low medium @medium
low high @hard
high low @hard
high medium @hard
high high @hard
CELLS
lane build --omp >"$T/out"
[ "$(last | jq -r '.model')" = '@hard' ] || fail 'ungraded default card takes the medium cell (@hard)'
lane review --omp --tier low >"$T/out"
[ "$(last | jq -r '.model')" = '@review' ] || fail 'review ignores the ladder'
lane review --omp=@easy >"$T/out"
[ "$(last | jq -r '.model')" = '@easy' ] || fail 'explicit --omp role pins every lane'

# omp.model pins too; the ladder is skipped.
jq '.omp.model = "pinned-config"' "$T/config.json" > "$T/config2.json"
bash "$KIT/scripts/super-board-omp-lane.sh" --config "$T/config2.json" --card "$CARD" --lane review --omp >"$T/out"
[ "$(last | jq -r '.model')" = 'pinned-config' ] || fail 'omp.model pins the lane'
RC=0; lane build --omp= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit role must refuse'

# Result sources: private file first, then the last NDJSON assistant message; malformed fails closed.
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_SKIP_FILE=1 lane build --omp >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail 'NDJSON fallback must recover the lane result'
RC=0; SB_OMP_TEST_INVALID=1 lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'invalid result fails closed'

# Caps: cost exit 3 and a deadline both halt, preserving the card.
RC=0; SB_OMP_TEST_EXIT=3 lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.status == "halted" and .detail == "cost-cap"' "$T/out" >/dev/null || fail 'cost cap halts'
RC=0; SB_OMP_TEST_TIME=1 lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.status == "halted" and .detail == "time-cap"' "$T/out" >/dev/null || fail 'time cap halts'

# A lane without the guard extension refuses to run unguarded.
mv .omp/extensions/super-board-guards.ts "$T/guards.ts"
: > "$SB_OMP_TEST_LOG"
RC=0; lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed" and (.detail | contains("guard extension"))' "$T/out" >/dev/null \
  || fail 'missing guard extension must fail closed'
[ ! -s "$SB_OMP_TEST_LOG" ] || fail 'unguarded lane must not launch'
mv "$T/guards.ts" .omp/extensions/super-board-guards.ts

# Wave: @classify router, tier/grade routing per card, marker and locks released.
CARDS='[{"number":1,"status":"Ready","title":"easy"},{"number":2,"status":"Review"}]'
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_GRADE=low wave --omp --tier low >"$T/out"
jq -e '.halted == false and (.cards | length) == 2 and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].column == "Done"' "$T/out" >/dev/null || fail 'wave routing/summary'
jq -s -e '
  ([.[] | select(.lane == "grade")] | length) == 1 and
  ([.[] | select(.lane == "grade")][0].model == "@classify") and
  ([.[] | select(.lane == "grade")][0].tools == "bash,read") and
  ([.[] | select(.number == 1 and .lane != "grade")][0].model == "@easy") and
  ([.[] | select(.number == 2)][0].model == "@review")
' "$SB_OMP_TEST_LOG" >/dev/null || fail 'wave must grade with @classify and route roles'
jq -sr 'map(select(.config != null)) | .[0].config' "$SB_OMP_TEST_LOG" > "$T/overlay.yml"
overlay_chains '{"easy":["fake/easy-2"],"review":[],"task":[]}' 'wave overlay'
[ ! -e .claude/super-board/omp-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed wave leaves no PID/worker locks'

# A pinned model skips the router and wins every lane.
: > "$SB_OMP_TEST_LOG"
wave --omp=pinned-model >"$T/out"
jq -s -e 'all(.lane != "grade") and all(.model == "pinned-model")' "$SB_OMP_TEST_LOG" >/dev/null || fail 'pinned wave skips the router'
: > "$SB_OMP_TEST_LOG"
CARDS='[{"number":1,"status":"Ready"}]'
RC=0; SB_OMP_TEST_GRADE_EXIT=79 wave --omp >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and .cards[0].finalStatus == "halted"' "$T/out" >/dev/null || fail 'router halt stops the wave'
jq -s -e 'all(.lane == "grade")' "$SB_OMP_TEST_LOG" >/dev/null || { cat "$SB_OMP_TEST_LOG" >&2; fail 'router halt launches no lane'; }

# A live in-flight lock halts that card; a stale PID is reclaimed.
CARDS='[{"number":1,"status":"Review"}]'
mkdir -p .claude/super-board/inflight
printf 'PID=%s\nLANE=review\n' "$$" > .claude/super-board/inflight/1
RC=0; wave --omp >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.cards[0].detail | contains("in-flight lock")' "$T/out" >/dev/null || fail 'live lock must halt'
printf 'PID=999999999\nLANE=review\n' > .claude/super-board/inflight/1
: > "$SB_OMP_TEST_LOG"
wave --omp >"$T/out"
jq -e '.cards[0].finalStatus == "advanced"' "$T/out" >/dev/null || fail 'stale lock must be reclaimed'
[ ! -e .claude/super-board/inflight/1 ] || fail 'reclaimed lock must be removed'

# Two cards in parallel under max_workers=2.
jq '.max_workers = 2' "$T/config.json" > "$T/config3.json"
CARDS='[{"number":1,"status":"Review"},{"number":2,"status":"Review"}]'
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_DELAY=1 bash "$KIT/scripts/super-board-omp-wave.sh" --config "$T/config3.json" --cards "$CARDS" --omp >"$T/out"
jq -s -e 'map(.active) | max == 2' "$SB_OMP_TEST_LOG" >/dev/null || fail 'max_workers=2 must run cards together'

echo 'PASS: test-omp-lane.sh (roles/ladders/review/allowlist/caps/extension/results/wave/locks)'
