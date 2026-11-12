#!/usr/bin/env bash
# Stubbed OMP only: model roles/pinning, review consent, caps, allowlist, guard
# extension, result file + NDJSON fallback + rejected-payload evidence, wave
# routing/concurrency/halt/locks.
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
import json,os,sys
args=sys.argv[1:]
if args[:2]==['api','graphql']:
    if os.environ.get('SB_OMP_TEST_BOARD_FAIL'):
        sys.exit('gh fixture: board read failed')
    status=os.environ.get('SB_OMP_TEST_BOARD','Ready')
    print(json.dumps({'data':{'repository':{'issueOrPullRequest':{'projectItems':{'nodes':[
        {'id':'ITEM1','project':{'number':7,'owner':{'login':'fixture'}},
         'fieldValueByName':{'name':status}}]}}}}}))
elif args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
chmod +x "$T/bin/gh"
export SB_OMP_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
export SB_GITHUB_RETRY_DELAY=0
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
last | jq -r '.prompt' | grep -q '@role · provider/model:thinking · <sha>' || fail 'the lane prompt must carry the PR history model contract'
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

# Each lane appends {card, lane, role, provider, model, thinking, cost} to the run's lanes.jsonl.
rm -f "$T/lanes.jsonl"
lane build --omp --tier medium --complexity low --evidence "$T/lanes.jsonl" >"$T/out"
jq -s -e 'length == 1 and .[0].card == 1 and .[0].lane == "build" and .[0].role == "medium"
          and .[0].provider == "fake" and .[0].model == "fake-model" and .[0].thinking == "low"
          and .[0].cost > 0.12 and .[0].cost < 0.14 and .[0].status == "advanced"' \
  "$T/lanes.jsonl" >/dev/null || fail 'a lane must persist its resolved model and cost'

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

# Result sources: private file first, then the NDJSON assistant messages newest
# first; prose (including an aborted subagent's last text) is skipped, never
# inherited; a payload that is not JSON or misses the schema is kept on disk and
# named by path, and the detail names every schema path that failed.
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_SKIP_FILE=1 lane build --omp >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail 'NDJSON fallback must recover the lane result'
SB_OMP_TEST_SKIP_FILE=1 SB_OMP_TEST_TRAILING='subagent still reviewing; no JSON here' lane build --omp >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail "an aborted subagent's trailing prose must not hide the lane result"
FUZZ='{"status":"advanced","column":"QA","detail":"x","prUrl":null,"branch":null,"priorFindings":null}'
SB_OMP_TEST_SKIP_FILE=1 SB_OMP_TEST_RESULT="Here is the lane result:
\`\`\`json
$FUZZ
\`\`\`
Done." lane build --omp >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail 'a fenced JSON result inside prose must be accepted'
REJECTED=.claude/super-board/rejected
rm -rf "$REJECTED"
RC=0; SB_OMP_TEST_RESULT='{"status":"advanced","column":"QA","detail":"x","prUrl":null,"priorFindings":null}' lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'a result missing a required key must fail closed'
jq -e '.detail | contains("required key missing") and contains("$.branch") and contains("lane-result-rejected-build-1.json")' "$T/out" >/dev/null \
  || fail 'the detail must name the missing key and the saved payload'
jq -e 'has("branch") | not' "$REJECTED/lane-result-rejected-build-1.json" >/dev/null \
  || fail 'the rejected payload must be preserved verbatim'
rm -rf "$REJECTED"
RC=0; SB_OMP_TEST_RESULT='{"status":"advanced","column":"QA","detail":"x","prUrl":null,"branch":null,"priorFindings":null,"note":"extra"}' lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] || fail 'a result with an extra key must fail closed'
jq -e '.detail | contains("unexpected key") and contains("$.note") and contains("lane-result-rejected-build-1.json")' "$T/out" >/dev/null \
  || fail 'the detail must name the extra key and the saved payload'
rm -rf "$REJECTED"
RC=0; SB_OMP_TEST_RESULT='{"status":"advanced","column":"QA","detail":"x","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"notFixed":0}}' lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.detail | contains("$.priorFindings.noLongerApplies: required key missing")' "$T/out" >/dev/null \
  || fail 'priorFindings must require all three counts'
rm -rf "$REJECTED"
RC=0; SB_OMP_TEST_SKIP_FILE=1 SB_OMP_TEST_RESULT='reviewed everything, looks good' lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.detail | contains("no JSON object") and contains("lane-result-rejected-build-1.txt")' "$T/out" >/dev/null \
  || fail 'prose must be preserved as text and named'
RC=0; SB_OMP_TEST_INVALID=1 lane build --omp >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'invalid result fails closed'

# Caps: cost exit 3 and a deadline both halt, preserving the card.
rm -f "$T/lanes.jsonl"
RC=0; SB_OMP_TEST_EXIT=3 lane build --omp --evidence "$T/lanes.jsonl" >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.status == "halted" and .detail == "cost-cap"' "$T/out" >/dev/null || fail 'cost cap halts'
jq -s -e '.[0].status == "halted" and .[0].cost > 0.12' "$T/lanes.jsonl" >/dev/null || fail 'a halted lane must still persist model and cost'
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
DEFAULT_LANES="docs/super-board/runs/$(date +%F)-config-omp/lanes.jsonl"
[ -s "$DEFAULT_LANES" ] || fail 'a wave without --output must persist lanes.jsonl under paths.runs_dir'
jq -s -e 'all(.[]; has("card") and has("lane") and has("role") and has("cost"))' "$DEFAULT_LANES" >/dev/null \
  || fail 'the default run directory must carry valid evidence records'

# The wave writes one evidence file in the run directory: the @classify grade plus
# every lane's resolved model and cost, so the model table needs no manual probe.
rm -rf "$T/run"
mkdir -p "$T/run"
SB_OMP_TEST_GRADE=low wave --omp --tier low --output "$T/run/wave-result.json" >"$T/out"
jq -s -e '
  (map(select(.lane == "classify")) | length) == 1 and
  (map(select(.lane == "classify"))[0].card == 1) and
  (map(select(.lane == "classify"))[0].complexity == "low") and
  (map(select(.lane == "classify"))[0].role == "classify") and
  (map(select(.lane == "classify"))[0].provider == "fake") and
  (map(select(.lane == "classify"))[0].model == "fake-model") and
  (map(select(.lane == "build"))[0].role == "easy") and
  (map(select(.lane == "qa"))[0].role == "easy") and
  (map(select(.lane == "review"))[0].role == "review") and
  all(.[]; has("card") and has("lane") and has("role") and has("provider")
            and has("model") and has("thinking") and has("cost"))
' "$T/run/lanes.jsonl" >/dev/null || fail 'the run must persist classify and lane model/cost evidence'
[ -f "$T/run/wave-result.json" ] || fail 'the wave output stays in the run directory'

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

# A lane that moves the card and then dies without a usable result reports the
# board's column and the move, never the column the card held at lane start.
jq '.project = {"owner":"fixture","number":7} | .repo = {"remote":"fixture/fixture"}' "$T/config.json" > "$T/board-config.json"
wave_board() { bash "$KIT/scripts/super-board-lane-wave.sh" --backend omp --config "$T/board-config.json" --cards "$CARDS" --omp=pinned-model 2>"$T/stderr"; }
CARDS='[{"number":1,"status":"Ready"}]'
: > "$SB_OMP_TEST_LOG"
RC=0; SB_OMP_TEST_INVALID=1 SB_OMP_TEST_BOARD=QA wave_board >"$T/out" || RC=$?
[ "$RC" -eq 0 ] || fail "a dead lane fails its card, not the wave (got $RC)"
jq -e '.halted == false and .cards[0].finalStatus == "failed" and .cards[0].column == "QA"' "$T/out" >/dev/null \
  || fail 'a failed lane must report the board column, not the entry column'
jq -e '.cards[0].detail | contains("no valid result (exit 1)") and contains("lane printed failed: OMP returned no valid lane result") and contains("board moved Ready → QA") and contains("payload preserved at") and contains("lane-result-rejected-build-1.txt")' "$T/out" >/dev/null \
  || fail 'the detail must keep the lane failure, name the board move and the saved payload'

RC=0; SB_OMP_TEST_INVALID=1 SB_OMP_TEST_BOARD=Ready wave_board >"$T/out" || RC=$?
[ "$RC" -eq 0 ] && jq -e '.cards[0].column == "Ready" and (.cards[0].detail | contains("board at Ready"))' "$T/out" >/dev/null \
  || fail 'an unmoved card must report the board column without a fake move'

# A lane that returns no result and leaves the board untouched is retried once.
rm -f "$SB_OMP_TEST_LOG.attempts"
CARDS='[{"number":1,"status":"Ready"}]'
: > "$SB_OMP_TEST_LOG"
RC=0; SB_OMP_TEST_INVALID_ONCE=1 SB_OMP_TEST_BOARD=Ready wave_board >"$T/out" || RC=$?
[ "$RC" -eq 0 ] && jq -e '.cards[0].finalStatus == "advanced" and (.cards[0].lanesRun | contains("build:failed → build:advanced"))' "$T/out" >/dev/null \
  || fail 'a no-result lane with an unmoved board must be retried once and advance'
[ "$(grep -c '"lane": "build"' "$SB_OMP_TEST_LOG")" -eq 2 ] || fail 'the retry must run the build lane exactly once more'
jq -e '.cards[0].detail | contains("retry after build returned no result")' "$T/out" >/dev/null \
  || fail 'the wave result must name the retry'

# A lane that moved the board did observable work and is never retried.
rm -f "$SB_OMP_TEST_LOG.attempts"
: > "$SB_OMP_TEST_LOG"
RC=0; SB_OMP_TEST_INVALID=1 SB_OMP_TEST_BOARD=QA wave_board >"$T/out" || RC=$?
[ "$RC" -eq 0 ] && jq -e '.cards[0].finalStatus == "failed"' "$T/out" >/dev/null || fail 'a moved board stays failed'
[ "$(grep -c '"lane": "build"' "$SB_OMP_TEST_LOG")" -eq 1 ] || fail 'a board move must not retry'

# An explicit failed result is a decision, not a trashed result: no retry.
rm -f "$SB_OMP_TEST_LOG.attempts"
: > "$SB_OMP_TEST_LOG"
RC=0; SB_OMP_TEST_STATUS=failed SB_OMP_TEST_BOARD=Ready wave_board >"$T/out" || RC=$?
[ "$RC" -eq 0 ] && jq -e '.cards[0].finalStatus == "failed"' "$T/out" >/dev/null || fail 'an explicit failed result stays failed'
[ "$(grep -c '"lane": "build"' "$SB_OMP_TEST_LOG")" -eq 1 ] || fail 'an explicit failed result must not retry'

# A failed lane keeps its OMP session and stderr, and the wave names the path.
rm -rf .claude/super-board/rejected
rm -f "$SB_OMP_TEST_LOG.attempts"
: > "$SB_OMP_TEST_LOG"
RC=0; SB_OMP_TEST_INVALID=1 SB_OMP_TEST_BOARD=QA wave_board >"$T/out" || RC=$?
DIAG=$(find .claude/super-board/rejected -maxdepth 1 -type d -name 'lane-diagnostics-build-1-*' | head -1)
[ -n "$DIAG" ] || fail 'a failed lane must preserve diagnostics'
[ -f "$DIAG/meta.json" ] && [ -f "$DIAG/stderr.txt" ] && [ -f "$DIAG/session/fake-session.jsonl" ] \
  || fail 'diagnostics must include meta, stderr and the OMP session'
jq -e '.status == "failed" and .lane == "build" and .card == 1' "$DIAG/meta.json" >/dev/null \
  || fail 'diagnostics meta must describe the failure'
jq -e '.cards[0].detail | test("diagnostics preserved at .*lane-diagnostics-build-1-")' "$T/out" >/dev/null \
  || fail 'wave result must name the diagnostics path'

# Without a readable board the wave halts and keeps the entry column, named as unread.
RC=0; SB_OMP_TEST_INVALID=1 SB_OMP_TEST_BOARD_FAIL=1 wave_board >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and .cards[0].finalStatus == "halted" and .cards[0].column == "Ready"' "$T/out" >/dev/null \
  || fail 'an unreadable board column must halt and keep the entry column'
jq -e '.cards[0].detail | contains("board column unread")' "$T/out" >/dev/null || fail 'the unread board must be named'
rm -f .claude/super-board/github-halt.json

# Two cards in parallel under max_workers=2 (QA lanes, not Review: reviews serialize).
jq '.max_workers = 2' "$T/config.json" > "$T/config3.json"
CARDS='[{"number":1,"status":"QA"},{"number":2,"status":"QA"}]'
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_DELAY=1 bash "$KIT/scripts/super-board-omp-wave.sh" --config "$T/config3.json" --cards "$CARDS" --omp >"$T/out"
jq -s -e 'map(.active) | max == 2' "$SB_OMP_TEST_LOG" >/dev/null || fail 'max_workers=2 must run QA lanes together'
PARALLEL_LANES="docs/super-board/runs/$(date +%F)-config3-omp/lanes.jsonl"
jq -s -e 'length >= 2 and all(.[]; has("card") and has("lane") and has("cost"))' "$PARALLEL_LANES" >/dev/null \
  || fail 'parallel lanes must append complete, parseable evidence records'

# Review lanes serialize: two cards in Review never enter the merge gate together.
CARDS='[{"number":1,"status":"Review"},{"number":2,"status":"Review"}]'
: > "$SB_OMP_TEST_LOG"
SB_OMP_TEST_DELAY=1 bash "$KIT/scripts/super-board-omp-wave.sh" --config "$T/config3.json" --cards "$CARDS" --omp >"$T/out"
jq -s -e 'map(select(.lane == "review") | .active) | max == 1' "$SB_OMP_TEST_LOG" >/dev/null \
  || fail 'review lanes must serialize'

echo 'PASS: test-omp-lane.sh (roles/ladders/review/allowlist/caps/extension/results/wave/locks)'
