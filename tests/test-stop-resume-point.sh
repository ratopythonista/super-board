#!/usr/bin/env bash
# The stop comment must name the branch tip even when the branch is checked
# out in another worktree: `git branch` then prints `+ <branch>`, and the `+`
# used to leak into `git log`, losing the resume point.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/repo/.claude/super-board/configs" "$TMP/repo/.claude/super-board/inflight"
printf '{"bot_identity":"bot"}\n' > "$TMP/repo/.claude/super-board/configs/test.json"
printf 'PID=999999999\nLANE=build\nSTARTED=now\n' > "$TMP/repo/.claude/super-board/inflight/12"

export STOP_TRACE="$TMP/trace"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STOP_TRACE"
SH
cat > "$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/"*

cd "$TMP/repo"
git init -q -b main
git config user.email test@example.com
git config user.name test
echo base > base.txt
git add base.txt
git commit -q -m "chore: base"
git branch issue-12-resume-point
git checkout -q issue-12-resume-point
echo fix > fix.txt
git add fix.txt
git commit -q -m "fix: keep the resume point"
SHORT=$(git rev-parse --short HEAD)
git checkout -q main
git worktree add -q "$TMP/wt" issue-12-resume-point

# Guard the scenario: the branch must be advertised with the worktree `+`.
git branch --list '*issue-12-*' | grep -q '^+ ' \
  || { echo 'FAIL: branch not shown as checked out in a worktree'; exit 1; }

(cd "$TMP/repo" && PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/super-board-stop.sh" test > stop.log)

grep -q "resume point is the last pushed commit — ${SHORT} fix: keep the resume point" "$STOP_TRACE" \
  || { echo 'FAIL: stop comment lost the worktree branch commit'; cat "$STOP_TRACE"; exit 1; }
if grep -q 'branch found but no commits' "$STOP_TRACE"; then
  echo 'FAIL: stop comment fell back to the empty-branch message'; exit 1
fi
echo 'PASS: test-stop-resume-point.sh (worktree-checked-out branch names its commit)'
