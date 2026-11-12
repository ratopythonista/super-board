#!/usr/bin/env bash
# One headless board lane on a non-Claude worker host, chosen by --backend.
# Usage: --backend codex --config f --card '<JSON>' --lane build|qa|review
#        [--<backend>[=model]] [--tier low|medium|high] [--complexity low|medium|high]
#        [--evidence <lanes.jsonl>]
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
import time

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)

def append_jsonl(path, record):
    """Append one record atomically; parallel lanes share the same evidence file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = (json.dumps(record) + '\n').encode()
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        os.write(descriptor, line)
    finally:
        os.close(descriptor)

def events(text):
    for line in (text or '').splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            yield event

def session_cost(directory):
    """USD spent by the lane from OMP's session files, subagents included when
    they share --session-dir. The files are the durable record; stdout is the
    fallback for hosts that do not write one."""
    total, seen = 0.0, False
    try:
        paths = list(Path(directory).rglob('*.jsonl'))
    except OSError:
        return None
    for path in paths:
        try:
            stream = path.open()
        except OSError:
            continue
        with stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get('type') == 'message':
                    message = event.get('message') or {}
                    if message.get('role') != 'assistant':
                        continue
                    value = ((message.get('usage') or {}).get('cost') or {}).get('total')
                elif event.get('type') == 'model_usage':
                    value = ((event.get('usage') or {}).get('cost') or {}).get('total')
                else:
                    continue
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    total += value
                    seen = True
    return round(total, 8) if seen else None

def output_cost(text):
    """USD from the NDJSON stream when no session file is available.

    `agent_end.telemetry` already aggregates the messages, so it wins over the
    per-message totals instead of being added to them."""
    telemetry = None
    messages_total, seen = 0.0, False
    for event in events(text):
        if event.get('type') == 'message_end':
            message = event.get('message') or {}
            value = ((message.get('usage') or {}).get('cost') or {}).get('total')
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                messages_total += value
                seen = True
        elif event.get('type') == 'agent_end':
            value = (((event.get('telemetry') or {}).get('cost') or {}).get('estimatedUsd'))
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                telemetry = value if telemetry is None else telemetry + value
    if telemetry is not None:
        return round(telemetry, 8)
    return round(messages_total, 8) if seen else None

def run_cost(run, stdout):
    cost = session_cost(run['session_dir'])
    return cost if cost is not None else output_cost(stdout)

def resolved_identity(model_file, requested):
    """(role, provider, model, thinking) from the guard extension's evidence file."""
    data = {}
    if model_file:
        try:
            loaded = json.loads(Path(model_file).read_text())
        except (OSError, ValueError):
            loaded = None
        if isinstance(loaded, dict):
            data = loaded
    role = data.get('role')
    if isinstance(role, str) and role.strip():
        role = role.strip().lstrip('@')
    else:
        role = requested[1:] if isinstance(requested, str) and requested.startswith('@') else None
    provider = data.get('provider') if isinstance(data.get('provider'), str) else None
    model = data.get('model') if isinstance(data.get('model'), str) else None
    if model is None and isinstance(requested, str) and not requested.startswith('@'):
        if '/' in requested:
            provider = provider or requested.split('/', 1)[0]
            model = requested.split('/', 1)[1]
        else:
            model = requested
    thinking = data.get('thinking') if isinstance(data.get('thinking'), str) else None
    return role, provider, model, thinking

def lane_evidence(run, stdout, status):
    role, provider, model, thinking = resolved_identity(run.get('model_file'), run.get('model'))
    return {'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'card': run['row'].get('number') if isinstance(run.get('row'), dict) else None,
            'lane': run.get('lane'), 'role': role, 'provider': provider, 'model': model,
            'thinking': thinking, 'cost': run_cost(run, stdout), 'status': status}

def default_evidence(config, root, backend_name, config_path):
    runs = Path(((config.get('paths') or {}).get('runs_dir') or 'docs/super-board/runs'))
    if not runs.is_absolute():
        runs = root / runs
    day = time.strftime('%Y-%m-%d', time.localtime())
    return runs / f'{day}-{config_path.stem}-{backend_name}' / 'lanes.jsonl'


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

    def final_messages(self, run, stdout):
        """Candidate result texts: the host's last message, which must be the lane result JSON."""
        return [run['output'].read_text()]


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
        # No --tier and no complexity is the medium run tier's medium cell.
        return '@review' if args.lane == 'review' else '@hard'

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
        lines.append('  fallbackChains:' + ('' if chains else ' {}'))
        for role, value in chains.items():
            if not isinstance(role, str) or not self.ROLE.fullmatch(role):
                raise ValueError(f'invalid omp.retry.fallbackChains role: {role!r}')
            if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
                raise ValueError(f'omp.retry.fallbackChains.{role} must be a string array')
            lines.append('    ' + role + ': [' + ', '.join(json.dumps(x) for x in value) + ']')
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

    def final_messages(self, run, stdout):
        """Candidate result texts: the private result file first, then every assistant
        message of the NDJSON stream, newest first.

        Aborted `task` subagents can emit their own last text as the session closes;
        the shared picker skips anything that is not a lane result, so a subagent's
        prose never hides the worker's JSON.
        """
        try:
            text = run['output'].read_text().strip()
        except OSError:
            text = ''
        candidates = [text] if text else []
        texts = []
        for line in (stdout or '').splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            if isinstance(event.get('message'), dict) and event['message'].get('role') == 'assistant':
                messages = [event['message']]
            elif event.get('type') == 'agent_end':
                messages = [message for message in reversed(event.get('messages') or [])
                            if isinstance(message, dict) and message.get('role') == 'assistant']
            else:
                continue
            for message in messages:
                text = ''.join(block.get('text', '') for block in message.get('content') or []
                               if isinstance(block, dict) and block.get('type') == 'text')
                if text.strip():
                    texts.append(text.strip())
        candidates.extend(reversed(texts))
        if not candidates:
            raise ValueError('no result file and no assistant text in --mode json output')
        return candidates


# One entry per worker host. A new host is one more class with the same members:
# name, label, LADDERS (or None), capture_stdout (True hands stdout to final_messages),
# command(run) and final_messages(run, stdout). Everything else in this file is shared.
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
parser.add_argument('--evidence', help='lanes.jsonl to append the resolved model/cost record to')
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
evidence_path = Path(args.evidence).expanduser().resolve() if args.evidence else None
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
last_detail = ''
def result(status, detail):
    global last_detail
    last_detail = detail
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
child = None
run = None
stderr = ''
evidence_status = {'status': 'failed'}

def preserve_diagnostics():
    """Keep the OMP session, stderr and resolved model of a failed lane.

    The temp session dir is deleted on exit, so a worker that ends before writing
    its result would otherwise leave only its last text. The wave names this path
    in `wave-result.json`; the next failure is diagnosable.
    """
    directory = (root / '.claude/super-board/rejected'
                 / f'lane-diagnostics-{args.lane}-{card["number"]}-{os.getpid()}')
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, exist_ok=True)
    session_dir = run['session_dir'] if run else None
    meta = dict(lane=args.lane, card=card['number'], model=model,
                returncode=child.returncode if child is not None else None,
                status=evidence_status['status'], detail=last_detail,
                at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    (directory / 'meta.json').write_text(json.dumps(meta, indent=2) + '\n')
    (directory / 'stderr.txt').write_text(stderr or '')
    if session_dir is not None and session_dir.is_dir():
        shutil.copytree(session_dir, directory / 'session')
    model_file = run['model_file'] if run else None
    if model_file is not None and model_file.is_file():
        shutil.copy2(model_file, directory / 'model.json')
    return directory
if backend.name == 'omp':
    bot = ((config.get('notifications') or {}).get('bot_identity') or config.get('bot_identity') or '')
    identity = f'`{bot}`' if bot else 'the authenticated `gh api user --jq .login` login'
    adaptation = f'''OMP adaptation: this is a headless `omp -p` lane process. Never launch Claude subagents. Use the native `task` tool only for Review's truth-check: two read-only adversarial passes (code-grounder and historian), with the Tester's evidence and the raw diff; every other duty runs inline. The guard extension narrows each subagent to read/bash/grep/glob.
Claim protocol: claim before work with `gh issue edit {card['number']} --add-assignee @me`; then `gh issue view {card['number']} --json assignees` must list exactly {identity}. A different assignee means another worker owns the card: return status=halted and preserve everything. Release only after the lane's final checklist passes.
Worktree: create your own at `.claude/worktrees/issue-{card['number']}-{args.lane}` and work only there; never edit the main checkout.
Merge vs nit: a finding is open only when the current diff, PR body or QA evidence still contains it. A historical comment that cites an older line, already corrected in the artifact, is `no longer applies`; note it and merge. A finding still present in the current artifact bounces, whatever the comment's age.
Evidence: read `$SUPER_BOARD_LANE_MODEL_FILE` (JSON role/provider/model/thinking written by the guard extension at session start) and use that resolved pair in the PR history line as `@role · provider/model:thinking · <sha>`.
Final lane result: write the JSON object (no prose) to {output_path} and also make it your last message.'''
else:
    adaptation = f'{backend.label} adaptation: do not launch Claude or other sub-agents. Perform preflight, classification, independent review and truth-check duties inline. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.'
prompt = f'''Run {skill} for issue #{card['number']} as a {backend.label} lane worker.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host {backend.name} --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>; if that exits 10, the helper is unavailable: skip it, continue inline, and never return halted for it (only the initial readiness recheck halts on exit 10).
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. A --kind diff read needs --meta <file> from a --kind metadata read first. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
{adaptation}
Return JSON: an object with ALL six keys, never omitted: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl=<PR URL> or null; branch=<branch name> or null; priorFindings=null, or on a Review re-review {{"fixed":<int>,"notFixed":<int>,"noLongerApplies":<int>}} with all three keys. A value you do not have is null, never absent, and no other keys are allowed. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
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
FENCE = re.compile(r'```(?:json)?[ \t]*\n?(.*?)```', re.S | re.I)

def json_kind(value):
    """The JSON type name of a Python value, so the error says what arrived."""
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'boolean'
    if isinstance(value, int):
        return 'integer'
    if isinstance(value, float):
        return 'number'
    if isinstance(value, str):
        return 'string'
    if isinstance(value, list):
        return 'array'
    if isinstance(value, dict):
        return 'object'
    return type(value).__name__

def matches_type(value, rule):
    kinds = rule.get('type')
    if kinds is None:
        return True
    for kind in kinds if isinstance(kinds, list) else [kinds]:
        if kind == 'integer':
            if type(value) is int:   # bool is not a JSON integer
                return True
        elif kind in JSON_TYPES and isinstance(value, JSON_TYPES[kind]):
            return True
    return False

def violations(value, rule, path='$'):
    """Every way `value` misses `rule`, with the schema path that failed.

    The subset of JSON Schema the lane schema uses: type, enum, anyOf,
    properties/required/additionalProperties. A missing key and an extra key
    must name themselves, which is why this is not a boolean.
    """
    if 'anyOf' in rule:
        options = rule['anyOf']
        typed = [option for option in options if matches_type(value, option)]
        for option in typed or options:
            if not violations(value, option, path):
                return []
        return violations(value, (typed or options)[0], path)
    if not matches_type(value, rule):
        expected = rule['type']
        expected = ' or '.join(expected) if isinstance(expected, list) else expected
        return [f'{path}: expected {expected}, got {json_kind(value)}']
    if 'enum' in rule and value not in rule['enum']:
        return [f'{path}: {json.dumps(value)} is not one of ' + ', '.join(str(item) for item in rule['enum'])]
    if isinstance(value, dict):
        found = [f'{path}.{key}: unexpected key' for key in value if key not in rule['properties']]
        found += [f'{path}.{key}: required key missing' for key in rule['required'] if key not in value]
        for key in value:
            if key in rule['properties']:
                found += violations(value[key], rule['properties'][key], f'{path}.{key}')
        return found
    return []

def conforms(value, rule):
    return not violations(value, rule)

def parse_result(text):
    """The lane result object from the final text: bare JSON, a ```json fence, or
    the first JSON object embedded in prose. Names what was wrong when none is there."""
    text = (text or '').strip()
    if not text:
        raise ValueError('empty result text')
    try:
        return json.loads(text)
    except ValueError:
        pass
    for match in FENCE.finditer(text):
        try:
            return json.loads(match.group(1))
        except ValueError:
            continue
    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character == '{':
            try:
                return decoder.raw_decode(text, index)[0]
            except ValueError:
                continue
    raise ValueError('no JSON object in the final text (prose or malformed JSON)')

def rejected_path(text):
    directory = root / '.claude/super-board/rejected'
    directory.mkdir(parents=True, exist_ok=True)
    try:
        json.loads(text)
    except ValueError:
        suffix = '.txt'
    else:
        suffix = '.json'
    return directory / f'lane-result-rejected-{args.lane}-{card["number"]}{suffix}'

def rejected(detail, text):
    """The failure line for a rejected payload, after keeping that payload on disk."""
    text = text or ''
    if not text.strip():
        return detail + '; payload was empty'
    try:
        path = rejected_path(text)
        path.write_text(text if text.endswith('\n') else text + '\n')
    except OSError as error:
        return f'{detail}; could not preserve the payload: {error}'
    return f'{detail}; payload preserved at {path}'

def choose_result(raws):
    """The first candidate that parses and conforms to the lane schema.

    A candidate that is prose (an aborted subagent's last text, a model that
    answered in words) is skipped, never inherited; a parsed payload that misses
    the schema names every bad path and leaves the payload on disk.
    """
    parse_error = first_parsed = None
    for raw in raws:
        try:
            value = parse_result(raw)
        except ValueError as error:
            parse_error = parse_error or error
            continue
        found = violations(value, schema)
        if not found:
            return value
        if first_parsed is None:
            first_parsed = (raw, found)
    if first_parsed is not None:
        raw, found = first_parsed
        raise ValueError(rejected('lane result does not match the lane schema: ' + '; '.join(found), raw))
    raise ValueError(rejected(str(parse_error or 'no result text'), raws[0]))

child = None
run = None
stdout = ''
evidence_status = {'status': 'failed'}
def interrupted(signum, frame):
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    evidence_status['status'] = 'halted'
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    run = dict(root=root, git_dir=git_dir, common_dir=common_dir, config=config, lane=args.lane,
               model=model, prompt=prompt, schema_path=Path(temporary) / 'schema.json',
               output=output_path, roles_path=Path(temporary) / 'roles.yml',
               session_dir=Path(temporary) / 'sessions',
               model_file=Path(temporary) / 'model.json', row=card,
               evidence=evidence_path or default_evidence(config, root, backend.name, config_path))
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
        try:
            require_verification_ready()
        except SystemExit as error:
            if error.code:
                evidence_status['status'] = 'halted'
            raise
        if child.returncode:
            special = backend.halted_detail(run, child.returncode, stdout, stderr) if hasattr(backend, 'halted_detail') else None
            evidence_status['status'] = 'halted' if special or child.returncode in (9, 10, 79) else 'failed'
            if special:
                result('halted', special)
                sys.exit(79)
            result('halted' if child.returncode in (9, 10, 79) else 'failed',
                   'verification-readiness: repair verify_commands and restart explicitly; preserve work'
                   if child.returncode == 9 else 'skills-readiness: required skills became unavailable; preserve work' if child.returncode == 10 else f"{' '.join(command[:2])} exited {child.returncode}")
            sys.exit(child.returncode if child.returncode in (9, 10, 79) else 1)
        parsed = choose_result(backend.final_messages(run, stdout))
        evidence_status['status'] = parsed['status']
        last_detail = parsed['detail']
        print(json.dumps(parsed))
        sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
                 else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
                 else 79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        result('failed', f'{backend.label} returned no valid lane result: {error}')
        sys.exit(1)
finally:
    if run is not None and child is not None:
        try:
            append_jsonl(run['evidence'], lane_evidence(run, stdout, evidence_status['status']))
        except OSError:
            pass   # evidence never blocks the lane result
    if evidence_status['status'] in ('failed', 'halted'):
        try:
            path = preserve_diagnostics()
            print(f'[lane] diagnostics preserved at {path}', file=sys.stderr)
        except OSError as error:
            print(f'[lane] could not preserve diagnostics: {error}', file=sys.stderr)
    shutil.rmtree(temporary, ignore_errors=True)
PY
