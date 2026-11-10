#!/usr/bin/env bash
# One headless board lane on a non-Claude worker host, chosen by --backend.
# Usage: --backend codex --config f --card '<JSON>' --lane build|qa|review
#        [--<backend>[=model]] [--tier low|medium|high] [--complexity low|medium|high]
# --<backend> (e.g. --codex) is the run owner's explicit opt-in; without it,
# usage fallback may build/test but must never own a review or merge, and the
# board config must say "usage_fallback": "<backend>" (exit 78 otherwise).
# Model: --<backend>=<model>, else <backend>.model, else the backend's LADDERS[tier][complexity]
# when --tier is given (an ungraded card takes the medium cell), else the host's default.
# A missing, unknown or not-yet-built backend exits 64 and names the valid ones.
# Shared here: input checks, readiness/GitHub gates, lane prompt, result schema and
# validation, signal handling. Per host: one class in BACKENDS below.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)


class Codex:
    """`codex exec` with a bounded permission profile; the answer lands in --output-last-message."""
    name, label = 'codex', 'Codex'
    # Codex run ladders, the one copy: run tier x card complexity -> model.
    # Mirrors the Claude LADDERS in workflows/super-board-wave.js. gpt-6.1-sol
    # ties gpt-6-astra on DeepSWE v1.1 (75.2% vs 74.1-74.8%) at a fifth of the
    # price, so it carries the default; Astra takes hard cards and --high.
    LADDERS = {
        'low': {'low': 'gpt-6-luna', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6.1-sol'},
        'medium': {'low': 'gpt-6.1-sol', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6-astra'},
        'high': {'low': 'gpt-6-astra', 'medium': 'gpt-6-astra', 'high': 'gpt-6-astra'},
    }
    capture_stdout = False  # Codex logs go to our stderr; the answer is a file
    capture_stderr = False

    def command(self, run):
        """(argv, stdin text) for one lane run; run holds root, git_dir, common_dir, model, prompt, schema_path, output."""
        # A custom profile deliberately does NOT extend :workspace, which protects
        # .git as read-only. Explicit git/common-dir grants also cover submodules.
        # https://learn.chatgpt.com/docs/permissions → File access limited to workspace
        filesystem = {':root': 'read', ':slash_tmp': 'write', ':tmpdir': 'write',
                      str(run['root']): 'write', str(run['git_dir']): 'write', str(run['common_dir']): 'write'}
        grants = '{' + ', '.join(json.dumps(key) + '=' + json.dumps(value) for key, value in filesystem.items()) + '}'
        command = ['codex', 'exec', '-C', str(run['root']), '-c', 'approval_policy="never"',
                   '-c', 'default_permissions="super-board-lane"',
                   '-c', 'permissions.super-board-lane.filesystem=' + grants,
                   '-c', 'permissions.super-board-lane.network.enabled=true',
                   '--output-schema', str(run['schema_path']), '--output-last-message', str(run['output']), '-']
        if run['model'] and run['model'].strip():
            command[2:2] = ['-m', run['model']]
        return command, run['prompt']

    def final_message(self, run, stdout):
        """The host's last message, which must be the lane result JSON."""
        return run['output'].read_text()


class Omp:
    """`omp -p` with an explicit model-role overlay, tool allowlist and guard extension."""
    name, label = 'omp', 'OMP'
    # Run tier x card complexity -> modelRoles alias. The roles resolve to concrete
    # provider/id pairs in the board config overlay; docs/hosts.md and ADR-0031 map
    # the defaults. Review never enters the ladder: it is always @review.
    LADDERS = {
        'low': {'low': '@easy', 'medium': '@medium', 'high': '@hard'},
        'medium': {'low': '@medium', 'medium': '@hard', 'high': '@hard'},
        'high': {'low': '@hard', 'medium': '@hard', 'high': '@hard'},
    }
    # The lane allowlist. `task` is added only for Review, where the truth-check
    # uses two read-only adversarial subagents; the extension narrows their tools.
    TOOLS = ['read', 'bash', 'edit', 'write', 'grep', 'glob', 'web_search']
    capture_stdout = True
    capture_stderr = True
    ROLE = re.compile(r'[A-Za-z][A-Za-z0-9_-]*\Z')
    DURATION = re.compile(r'\d+(?:\.\d+)?(?:ms|s|m|h)\Z')

    def tools(self, run):
        return self.TOOLS + (['task'] if run.get('lane') == 'review' else [])

    def default_model(self, args):
        return '@review' if args.lane == 'review' else '@medium'

    def limits(self, config, lane):
        block = config.get('omp') or {}
        if not isinstance(block, dict):
            raise ValueError('omp must be an object')
        limits = block.get('limits')
        if limits is None:
            return {}, {}
        if not isinstance(limits, dict):
            raise ValueError('omp.limits must be an object')
        spec = limits.get(lane, {})
        if spec is None:
            return {}, {}
        if not isinstance(spec, dict):
            raise ValueError(f'omp.limits.{lane} must be an object')
        cost, duration = spec.get('max_cost'), spec.get('max_time')
        if cost is not None and (type(cost) not in (int, float) or cost <= 0):
            raise ValueError(f'omp.limits.{lane}.max_cost must be a positive number')
        if duration is not None and (not isinstance(duration, str) or not self.DURATION.fullmatch(duration)):
            raise ValueError(f'omp.limits.{lane}.max_time must look like 30m, 600s or 1h')
        return ({'--max-cost': str(cost)} if cost is not None else {},
                {'--max-time': duration} if duration is not None else {})

    def overlay(self, config):
        """The per-run config.yml overlay: modelRoles and retry.fallbackChains."""
        block = config.get('omp') or {}
        if not isinstance(block, dict):
            raise ValueError('omp must be an object')
        retry = block.get('retry') or {}
        if not isinstance(retry, dict):
            raise ValueError('omp.retry must be an object')
        roles, chains = block.get('modelRoles') or {}, retry.get('fallbackChains') or {}
        if not isinstance(roles, dict) or not isinstance(chains, dict):
            raise ValueError('omp.modelRoles and omp.retry.fallbackChains must be objects')
        lines = ['modelRoles:']
        for role, value in roles.items():
            if not isinstance(role, str) or not self.ROLE.fullmatch(role):
                raise ValueError(f'invalid omp.modelRoles role: {role!r}')
            if isinstance(value, str):
                value = [value]
            if (not isinstance(value, list) or not value
                    or not all(isinstance(x, str) and x.strip() and '\n' not in x for x in value)):
                raise ValueError(f'omp.modelRoles.{role} must be a non-empty string or string array')
            lines.append('  ' + role + ': ' + json.dumps(', '.join(value)))
        lines.append('retry:')
        lines.append('  fallbackChains:')
        for role, value in chains.items():
            if not isinstance(role, str) or not self.ROLE.fullmatch(role):
                raise ValueError(f'invalid omp.retry.fallbackChains role: {role!r}')
            if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
                raise ValueError(f'omp.retry.fallbackChains.{role} must be a string array')
            lines.append('  ' + role + ': [' + ', '.join(json.dumps(x) for x in value) + ']')
        return '\n'.join(lines) + '\n'

    def guard_extension(self, root):
        for path in (root / '.omp/extensions/super-board-guards.ts',
                     root / '.agents/extensions/super-board-guards.ts'):
            if path.is_file():
                return path
        raise ValueError('guard extension missing: reinstall with install.sh --hosts omp')

    def command(self, run):
        config, lane = run['config'], run['lane']
        limits = self.limits(config, lane)
        run['roles_path'].write_text(self.overlay(config))
        role = run['model'][1:] if run['model'].startswith('@') else None
        roles = (config.get('omp') or {}).get('modelRoles') or {}
        if role and role not in roles:
            raise ValueError(f'omp.modelRoles.{role} is required by --model {run["model"]}')
        run['session_dir'].mkdir(parents=True, exist_ok=True)
        tools = self.tools(run)
        command = ['omp', '-p', '--mode', 'json', '--no-title', '--auto-approve',
                   '--tools', ','.join(tools), '--config', str(run['roles_path']),
                   '--model', run['model'], '--no-extensions',
                   '-e', str(self.guard_extension(run['root'])),
                   '--session-dir', str(run['session_dir'])]
        for flags in limits:
            for flag, value in flags.items():
                command += [flag, value]
        command.append(run['prompt'])
        return command, None

    def environment(self, run):
        tools = self.tools(run)
        return dict(os.environ,
                    SUPER_BOARD_RUN='1',
                    SUPER_BOARD_LANE_ROLE=run['model'],
                    SUPER_BOARD_LANE_TOOLS=','.join(tools),
                    SUPER_BOARD_LANE_MODEL_FILE=str(run['model_file']),
                    CLAUDE_PROJECT_DIR=str(run['root']))

    def halted_detail(self, run, returncode, stdout, stderr):
        if returncode == 3:
            return 'cost-cap'
        if returncode == 1 and re.search(r'deadline exceeded|max[- ]time', (stderr or '') + (stdout or ''), re.I):
            return 'time-cap'
        return None

    def final_message(self, run, stdout):
        try:
            text = run['output'].read_text().strip()
        except OSError:
            text = ''
        if text:
            return text
        # --mode json: the last assistant message is the lane result when the
        # worker did not write the result file. Fail closed on anything else.
        last = None
        for line in (stdout or '').splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            message = event.get('message')
            if isinstance(message, dict) and message.get('role') == 'assistant':
                last = message
            elif event.get('type') == 'agent_end':
                for message in reversed(event.get('messages') or []):
                    if isinstance(message, dict) and message.get('role') == 'assistant':
                        last = message
                        break
        if not isinstance(last, dict):
            raise ValueError('no result file and no assistant message in --mode json output')
        text = ''.join(block.get('text', '') for block in last.get('content') or []
                       if isinstance(block, dict) and block.get('type') == 'text')
        if not text.strip():
            raise ValueError('last assistant message has no text')
        return text


# One entry per worker host. A new host is one more class with the same members:
# name, label, LADDERS (or None), capture_stdout (True hands stdout to final_message),
# command(run) and final_message(run, stdout). Everything else in this file is shared.
BACKENDS = {backend.name: backend for backend in [Codex(), Omp()]}

raw = sys.argv[2:]
choice = None
for index, arg in enumerate(raw):
    if arg == '--backend' or arg.startswith('--backend='):
        choice = arg.partition('=')[2] if '=' in arg else (raw[index + 1] if index + 1 < len(raw) else '')
        del raw[index:index + (1 if '=' in arg else 2)]
        break
if choice not in BACKENDS:
    fail(('missing --backend' if choice is None else f'unknown or not-yet-built backend {choice!r}')
         + '; valid backends: ' + ', '.join(BACKENDS))
backend = BACKENDS[choice]
flag = '--' + backend.name

parser = argparse.ArgumentParser(description=f'Run one {backend.label} board lane (no Claude sub-agents).')
parser.add_argument('--config', required=True)
parser.add_argument('--card', required=True, help='card JSON or a JSON file')
parser.add_argument('--lane', required=True, choices=['build', 'qa', 'review'])
parser.add_argument('--tier', choices=['low', 'medium', 'high'], help='run ladder (--low / default / --high)')
parser.add_argument('--complexity', choices=['low', 'medium', 'high'], help="router's grade for this card")
explicit = False
model = None
rest = []
for arg in raw:
    if arg == flag:
        explicit = True
    elif arg.startswith(flag + '='):
        explicit = True
        model = arg.partition('=')[2]
        if not model.strip():
            fail(f'{flag}=<model> requires a non-empty model')
    else:
        rest.append(arg)
args = parser.parse_args(rest)
script_path = Path(sys.argv[1]).resolve()
if args.lane == 'review' and not explicit:
    fail(f'{backend.label} review refused: run must be started with explicit {flag}; usage fallback cannot review.', 78)
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    configured = config.get(backend.name, {}).get('model') if config.get(backend.name) else None
    if configured is not None and not isinstance(configured, str):
        raise ValueError(f'{backend.name}.model must be a string')
    model = model if model is not None else (configured if configured and configured.strip() else None)
    if model is None and backend.name == 'omp' and args.lane == 'review':
        model = '@review'   # review never enters the ladder, even with --tier
    if model is None and args.tier and backend.LADDERS:
        model = backend.LADDERS[args.tier][args.complexity or 'medium']
    if model is None and backend.name == 'omp':
        model = backend.default_model(args)
        if not model:
            raise ValueError('omp lane needs a model role')
except (OSError, ValueError, AttributeError) as error:
    fail(f'Invalid {backend.label} lane input: {error}')
# Without --<backend> this is the usage fallback, and that is opt-in per board.
if not explicit and config.get('usage_fallback', 'none') != backend.name:
    fail(f'{backend.label} fallback refused: usage_fallback is not "{backend.name}" in {config_path}; pass {flag} for an explicit {backend.label} run.', 78)

column = card['status']
def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))

readiness = script_path.with_name('super-board-verification-ready.py')
def require_verification_ready():
    if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
        result('halted', 'verification-readiness: repair verify_commands; preserve claims, worktrees and card state, then restart explicitly')
        sys.exit(9)
require_verification_ready()

def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()

try:
    root = git_path('--show-toplevel')
    git_dir = git_path('--git-dir')
    common_dir = git_path('--git-common-dir')
except subprocess.CalledProcessError:
    fail(f'{backend.label} lane must start inside the target git repository')
os.chdir(root)
helper = script_path.with_name('super-board-github-read.py')
if not helper.exists() or subprocess.run([sys.executable, str(helper), '--check']).returncode:
    result('halted', 'required GitHub reads halted or helper missing; preserve claims and worktrees')
    sys.exit(79)

resolver_path = script_path.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate([card], root)
    skills = resolver.report(root, backend.name, [card], lane=args.lane,
                             home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    result('halted', 'required GitHub reads halted while hydrating skills; preserve claims and worktrees')
    sys.exit(error.code)
except (OSError, ValueError, TypeError, KeyError) as error:
    result('halted', 'skills-readiness: ' + str(error))
    sys.exit(64)
if not skills['ready']:
    result('halted', 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing')))
    sys.exit(10)

skill = {'build': 'super-build', 'qa': 'super-qa', 'review': 'super-review'}[args.lane]
section = {'build': 'Builder', 'qa': 'Tester', 'review': 'Reviewer'}[args.lane]
temporary = tempfile.mkdtemp(prefix=f'super-board-{backend.name}-')
output_path = Path(temporary) / 'result.json'
if backend.name == 'omp':
    bot = ((config.get('notifications') or {}).get('bot_identity') or config.get('bot_identity') or '')
    identity = f'`{bot}`' if bot else 'the authenticated `gh api user --jq .login` login'
    adaptation = f'''OMP adaptation: this is a headless `omp -p` lane process. Never launch Claude subagents. Use the native `task` tool only for Review's truth-check: two read-only adversarial passes (code-grounder and historian), with the Tester's evidence and the raw diff; every other duty runs inline. The guard extension narrows each subagent to read/bash/grep/glob.
Claim protocol: claim before work with `gh issue edit {card['number']} --add-assignee @me`; then `gh issue view {card['number']} --json assignees` must list exactly {identity}. A different assignee means another worker owns the card: return status=halted and preserve everything. Release only after the lane's final checklist passes.
Worktree: create your own at `.claude/worktrees/issue-{card['number']}-{args.lane}` and work only there; never edit the main checkout.
Evidence: read `$SUPER_BOARD_LANE_MODEL_FILE` (JSON role/provider/model/thinking written by the guard extension at session start) and use that resolved pair in the PR history line as `@role · provider/model:thinking · <sha>`.
Final lane result: write the JSON object (no prose) to {output_path} and also make it your last message.'''
else:
    adaptation = f'{backend.label} adaptation: do not launch Claude or other sub-agents. Perform preflight, classification, independent review and truth-check duties inline. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.'
prompt = f'''Run {skill} for issue #{card['number']} as a {backend.label} lane worker.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host {backend.name} --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>.
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. A --kind diff read needs --meta <file> from a --kind metadata read first. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
{adaptation}
Return JSON: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
'''
if args.lane == 'build':
    prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. Existing docs/ux/tests/refactor/tech-debt rows keep their label chain: classify complexity without adding feature/bug. If truly untyped, classify feature or bug, re-run skills-ready on the proposed labelled card before adding that label, never qa. Then follow the Builder lifecycle.
'''
elif args.lane == 'qa' and card['status'] == 'Ready':
    prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'
elif args.lane == 'review':
    prompt += f'''The owner explicitly chose run {flag}: you may review and own the merge. First load the latest <!-- super-review:report -->; grade prior R-ids fixed/not fixed/no longer applies, bounce any not fixed and edit the same report in place. Form hypotheses from the issue AC and diff before reading the Builder narrative.
Rerun the Tester's tests. When truth_gate triggers, apply super-review's fixed Adversarial mode brief inline in two distinct passes (code-grounder and historian); collect evidence and aggregate confidence against truth_threshold. Over-engineering is Should fix, never Blocker alone and never lowers confidence. Missing evidence fails closed.
Merge ONLY through the unchanged .claude/bin/super-board-merge-gate.sh, pinning the exact head you reviewed at review pass using --expect-head "$HEAD" --config <config> --pr <N> --subject <title> --body-file <msg.md>. Never run bare gh pr merge or bypass the gate. Follow run.md Merge protocol and route every gate exit exactly: 2/5 rebase pass, 3 Blocked, 4 stay Review, 6 fresh review, 7/8 human gate with pinned approval-request; 9 verification-readiness means halt and preserve card/worktree/approval/claims until config repair and explicit restart, never a Build bounce or rebase retry. Respect human_approves_merge and merge_policy. Confirm MERGED <sha>, fetch base and prove merge-base --is-ancestor <sha> origin/<base> before closing issue or moving Done.
'''

counts = {key: {'type': 'integer'} for key in ['fixed', 'notFixed', 'noLongerApplies']}
properties = {
    'status': {'type': 'string', 'enum': ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']},
    'column': {'type': 'string'}, 'detail': {'type': 'string'},
    'prUrl': {'type': ['string', 'null']}, 'branch': {'type': ['string', 'null']},
    'priorFindings': {'anyOf': [{'type': 'null'}, {'type': 'object', 'properties': counts,
                      'required': list(counts), 'additionalProperties': False}]},
}
schema = {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}
JSON_TYPES = {'object': dict, 'array': list, 'string': str, 'null': type(None)}
def conforms(value, rule):
    # The subset of JSON Schema the lane schema uses: type, enum, anyOf, properties/required/additionalProperties.
    if 'anyOf' in rule:
        return any(conforms(value, option) for option in rule['anyOf'])
    kinds = rule['type'] if isinstance(rule['type'], list) else [rule['type']]
    if not any(type(value) is int if kind == 'integer' else isinstance(value, JSON_TYPES[kind]) for kind in kinds):
        return False
    if 'enum' in rule and value not in rule['enum']:
        return False
    if isinstance(value, dict):
        if set(value) - set(rule['properties']) or not set(rule['required']) <= set(value):
            return False
        return all(conforms(value[key], rule['properties'][key]) for key in value)
    return True
child = None
def interrupted(signum, frame):
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    run = dict(root=root, git_dir=git_dir, common_dir=common_dir, config=config, lane=args.lane,
               model=model, prompt=prompt, schema_path=Path(temporary) / 'schema.json',
               output=output_path, roles_path=Path(temporary) / 'roles.yml',
               session_dir=Path(temporary) / 'sessions',
               model_file=Path(temporary) / 'model.json', row=card)
    run['schema_path'].write_text(json.dumps(schema))
    try:
        command, stdin = backend.command(run)
    except (OSError, ValueError) as error:
        result('failed', f'{backend.label} could not start: {error}')
        sys.exit(1)
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE if backend.capture_stdout else sys.stderr,
                                 stderr=subprocess.PIPE if backend.capture_stderr else None,
                                 env=backend.environment(run) if hasattr(backend, 'environment') else None,
                                 text=True)
        stdout, stderr = child.communicate(stdin)
        require_verification_ready()
        if child.returncode:
            special = backend.halted_detail(run, child.returncode, stdout, stderr) if hasattr(backend, 'halted_detail') else None
            if special:
                result('halted', special)
                sys.exit(79)
            result('halted' if child.returncode in (9, 10, 79) else 'failed',
                   'verification-readiness: repair verify_commands and restart explicitly; preserve work'
                   if child.returncode == 9 else 'skills-readiness: required skills became unavailable; preserve work' if child.returncode == 10 else f"{' '.join(command[:2])} exited {child.returncode}")
            sys.exit(child.returncode if child.returncode in (9, 10, 79) else 1)
        parsed = json.loads(backend.final_message(run, stdout))
        if not conforms(parsed, schema):
            raise ValueError('lane result does not match the lane schema')
        print(json.dumps(parsed))
        sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
                 else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
                 else 79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        result('failed', f'{backend.label} returned no valid lane result: {error}')
        sys.exit(1)
finally:
    shutil.rmtree(temporary, ignore_errors=True)
PY
