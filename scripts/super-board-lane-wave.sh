#!/usr/bin/env bash
# Dispatch an explicitly selected lane wave; stdout/--output matches the Claude
# workflow's {cards:[summary...], halted} reconciliation contract.
# Usage: --backend codex|omp --config f --cards '<JSON array>' --<backend>[=model]
#        [--tier low|medium|high] [--output f]
# `super-board-codex-wave.sh` and `super-board-omp-wave.sh` are wrappers for the
# two backends. Unless one model is pinned (--<backend>=<model> or
# <backend>.model), a cheap router grades each Ready card low/medium/high; the
# lane launcher maps tier x grade through backend.LADDERS, or (OMP) resolves the
# role in the board's modelRoles overlay.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

raw = sys.argv[2:]
choice = None
for index, arg in enumerate(raw):
    if arg == '--backend' or arg.startswith('--backend='):
        choice = arg.partition('=')[2] if '=' in arg else (raw[index + 1] if index + 1 < len(raw) else '')
        del raw[index:index + (1 if '=' in arg else 2)]
        break
if choice not in ('codex', 'omp'):
    print(('missing --backend' if choice is None else f'unknown wave backend {choice!r}')
          + '; valid backends: codex, omp', file=sys.stderr)
    sys.exit(64)
backend = choice
flag = '--' + backend

parser = argparse.ArgumentParser(description=f'Dispatch one explicitly opted-in {backend} wave.')
parser.add_argument('--config', required=True)
parser.add_argument('--cards', required=True, help='planner card array JSON or JSON file')
parser.add_argument('--output')
parser.add_argument('--tier', default='medium', choices=['low', 'medium', 'high'])
explicit = [arg for arg in raw if arg == flag or arg.startswith(flag + '=')]
if len(explicit) != 1 or (explicit[0].startswith(flag + '=') and not explicit[0].partition('=')[2].strip()):
    parser.error(f'exactly one explicit {flag}[=<non-empty-model>] is required')
args = parser.parse_args([arg for arg in raw if arg not in explicit])
output_path = Path(args.output).resolve() if args.output else None
launcher = Path(sys.argv[1]).resolve().with_name('super-board-lane.sh')
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    cards = json.loads(args.cards if args.cards.lstrip().startswith('[') else Path(args.cards).read_text())
    if not isinstance(config, dict) or not isinstance(cards, list):
        raise ValueError('config must be an object; cards must be an array')
    numbers = set()
    for card in cards:
        if (not isinstance(card, dict) or type(card.get('number')) is not int or card['number'] < 1
                or card.get('status') not in ['Ready', 'QA', 'Review']):
            raise ValueError('each card needs a positive number and Ready/QA/Review status')
        if card['number'] in numbers:
            raise ValueError('duplicate card number')
        numbers.add(card['number'])
        if card.get('lane') not in [None, 'build', 'qa', 'review']:
            raise ValueError('invalid card lane')
        if card['status'] == 'Ready' and card.get('lane') == 'review':
            raise ValueError('a Ready card must enter build or qa')
    workers = config.get('max_workers', 0)
    if type(workers) is not int or workers < 0:
        raise ValueError('max_workers must be a non-negative integer')
    workers = workers or (4 if backend == 'omp' else max(1, min(16, (os.cpu_count() or 2) - 2)))
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
    configured = (config.get(backend) or {}).get('model')
    pinned = explicit[0].startswith(flag + '=') or (isinstance(configured, str) and configured.strip())
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    parser.error(str(error))
readiness = launcher.with_name('super-board-verification-ready.py')
if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
    result = json.dumps({'cards': [dict(number=c['number'], finalStatus='halted', lastLane='none',
                                       column=c['status'], detail='verification-readiness: repair verify_commands and restart explicitly',
                                       prUrl=None, priorFindings=None, lanesRun='none:halted') for c in cards], 'halted': True})
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(9)
os.chdir(root)
resolver_path = launcher.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate(cards, root)
    skills = resolver.report(root, backend, cards, home=os.environ.get('SUPER_BOARD_SKILLS_HOME'),
                             catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    code, detail = error.code, 'required GitHub reads halted while hydrating skills; preserve claims and worktrees'
except (OSError, ValueError, TypeError, KeyError) as error:
    code, detail = 64, 'skills-readiness: ' + str(error)
else:
    code = 0 if skills['ready'] else 10
    detail = 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing'))
if code:
    result = json.dumps(dict(cards=[dict(number=c['number'], finalStatus='halted', lastLane='none', column=c['status'],
                                       detail=detail, prUrl=None, priorFindings=None, lanesRun='none:halted') for c in cards], halted=True))
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(code)
readiness_halted = threading.Event()
skills_halted = threading.Event()
halted = threading.Event()
mutex = threading.RLock()
active = set()
inflight = root / '.claude/super-board/inflight'
marker = root / f'.claude/super-board/{backend}-wave.pid'
inflight.mkdir(parents=True, exist_ok=True)
owner = str(os.getpid())

def cancel(signum, frame):
    halted.set()
    with mutex:
        processes = list(active)
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    # Process groups include the launcher, the host, and shell descendants. Kill
    # lingering descendants too, even when their launcher already exited.
    time.sleep(2)
    for process in processes:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
try:
    with marker.open('x') as stream:
        stream.write(owner + '\n')
except FileExistsError:
    parser.error(f'{backend} wave PID marker exists; reconcile the previous wave before starting another')

# The router only grades scope; it writes nothing. A Codex run grades with the
# cheapest Codex model. An OMP run resolves @classify from the same overlay the
# lanes use, because OMP has no --output-schema: the result is written to a
# temp file and validated here.
ROUTER_MODEL = 'gpt-6-luna'
ROUTER_TOOLS = 'bash,read'
GRADE_SCHEMA = {'type': 'object', 'additionalProperties': False, 'required': ['complexity'],
                'properties': {'complexity': {'type': 'string', 'enum': ['low', 'medium', 'high']}}}

def omp_overlay(config):
    """The OMP config.yml overlay (modelRoles + retry.fallbackChains)."""
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
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', str(role)):
            raise ValueError(f'invalid omp.modelRoles role: {role!r}')
        if isinstance(value, str):
            value = [value]
        if (not isinstance(value, list) or not value
                or not all(isinstance(x, str) and x.strip() and '\n' not in x for x in value)):
            raise ValueError(f'omp.modelRoles.{role} must be a non-empty string or string array')
        lines.append('  ' + role + ': ' + json.dumps(', '.join(value)))
    lines += ['retry:', '  fallbackChains:' + ('' if chains else ' {}')]
    for role, value in chains.items():
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', str(role)):
            raise ValueError(f'invalid omp.retry.fallbackChains role: {role!r}')
        if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
            raise ValueError(f'omp.retry.fallbackChains.{role} must be a string array')
        lines.append('    ' + role + ': [' + ', '.join(json.dumps(x) for x in value) + ']')
    return '\n'.join(lines) + '\n'

def omp_limit(config, lane):
    block = config.get('omp') or {}
    if not isinstance(block, dict):
        raise ValueError('omp must be an object')
    spec = (block.get('limits') or {}).get(lane) or {}
    if not isinstance(spec, dict):
        raise ValueError(f'omp.limits.{lane} must be an object')
    cost, duration = spec.get('max_cost'), spec.get('max_time')
    if cost is not None and (type(cost) not in (int, float) or cost <= 0):
        raise ValueError(f'omp.limits.{lane}.max_cost must be a positive number')
    if duration is not None and (not isinstance(duration, str) or not re.fullmatch(r'\d+(?:\.\d+)?(?:ms|s|m|h)', duration)):
        raise ValueError(f'omp.limits.{lane}.max_time must look like 3m, 90s or 1h')
    return (['--max-cost', str(cost)] if cost is not None else []) + (['--max-time', duration] if duration else [])

def omp_extension():
    for path in (root / '.omp/extensions/super-board-guards.ts', root / '.agents/extensions/super-board-guards.ts'):
        if path.is_file():
            return path
    raise ValueError('guard extension missing: reinstall with install.sh --hosts omp')

def last_assistant_text(stdout):
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
        return None
    text = ''.join(block.get('text', '') for block in last.get('content') or []
                   if isinstance(block, dict) and block.get('type') == 'text')
    return text.strip() or None

def read_grade(path, stdout):
    try:
        text = path.read_text().strip()
    except OSError:
        text = last_assistant_text(stdout) or ''
    try:
        value = json.loads(text).get('complexity')
    except (ValueError, AttributeError):
        return None
    return value if value in ['low', 'medium', 'high'] else None

def grade(card):
    """Return (complexity or None, halted). A failed grade falls back to the medium cell."""
    if pinned or card['status'] != 'Ready':
        return card.get('complexity') if card.get('complexity') in ['low', 'medium', 'high'] else None, False
    if card.get('complexity') in ['low', 'medium', 'high']:
        return card['complexity'], False
    prompt = (f"Read GitHub issue #{card['number']} (\"{card.get('title', '')}\") - body and all comments - with "
              f".claude/bin/super-board-github-read.py --kind issue -- issue view {card['number']} --json number,title,body and "
              f"--kind comments -- api repos/{{owner}}/{{repo}}/issues/{card['number']}/comments --paginate --slurp. "
              'Grade complexity (low|medium|high) by the scope of change required. Read only: change no file, '
              'label, comment or board state. Exit 79 from the read helper means stop and return nothing.\n')
    with tempfile.TemporaryDirectory(prefix=f'super-board-{backend}-grade-') as temporary:
        schema_path, output = Path(temporary) / 'schema.json', Path(temporary) / 'grade.json'
        schema_path.write_text(json.dumps(GRADE_SCHEMA))
        environment = dict(os.environ, SUPER_BOARD_LANE_TOOLS=ROUTER_TOOLS,
                           SUPER_BOARD_SKIP_CLEANUP='1', CLAUDE_PROJECT_DIR=str(root))
        if backend == 'codex':
            command = ['codex', 'exec', '-m', ROUTER_MODEL, '-C', str(root), '-c', 'approval_policy="never"',
                       '-c', 'default_permissions="super-board-grade"',
                       '-c', 'permissions.super-board-grade.filesystem={":root"="read", ":slash_tmp"="write", ":tmpdir"="write"}',
                       '-c', 'permissions.super-board-grade.network.enabled=true',
                       '--output-schema', str(schema_path), '--output-last-message', str(output), '-']
            stdin, capture_stdout = prompt, False
        else:
            roles = Path(temporary) / 'roles.yml'
            roles.write_text(omp_overlay(config))
            prompt += f'\nWrite exactly {{"complexity":"low|medium|high"}} to {output} and nothing else.\n'
            command = ['omp', '-p', '--mode', 'json', '--no-title', '--auto-approve', '--no-skills',
                       '--tools', ROUTER_TOOLS, '--config', str(roles), '--model', '@classify',
                       '--no-extensions', '-e', str(omp_extension()),
                       '--session-dir', str(Path(temporary) / 'sessions')] + omp_limit(config, 'classify') + [prompt]
            stdin, capture_stdout = None, True
        with mutex:
            if halted.is_set():
                return None, True
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                           stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL, env=environment, text=True,
                                           start_new_session=True)
            except OSError:
                return None, False
            active.add(process)
        stdout = ''
        try:
            stdout, _ = process.communicate(stdin)
        finally:
            with mutex:
                active.discard(process)
        if process.returncode == 79:
            return None, True
        return read_grade(output, stdout), False

def live_lock(lock):
    """True when a regular in-flight lock belongs to a live process; stale locks are removed."""
    if not lock.is_file():
        return False
    try:
        first = lock.read_text().strip().split('\n')[0]
        pid = int(first.split('=', 1)[1] if first.startswith('PID=') else first)
    except (OSError, ValueError, IndexError):
        return True   # unreadable lock: fail closed rather than race its owner
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        lock.unlink(missing_ok=True)
        return False
    except PermissionError:
        return True

def run_card(card):
    complexity, stop = grade(card)
    if stop:
        halted.set()
        return dict(number=card['number'], finalStatus='halted', lastLane='none', column=card['status'],
                    detail='run halted while grading; preserve claims and worktrees', prUrl=None,
                    priorFindings=None, lanesRun='none:halted')
    labels = [str(label).lower() for label in card.get('labels', [])]
    first = card.get('lane') or ('qa' if 'qa' in labels else 'build')
    entry = 'review' if card['status'] == 'Review' else 'qa' if card['status'] == 'QA' else first
    lanes = ['build', 'qa', 'review'][['build', 'qa', 'review'].index(entry):]
    history = []
    current = dict(card)
    for lane in lanes:
        with mutex:
            if halted.is_set():
                history.append(dict(lane='none', status='halted', column=current['status'], detail='run halted; preserve claims and worktrees'))
                break
            boundary = resolver.report(root, backend, [current], lane=lane,
                                       home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
            if not boundary['ready']:
                skills_halted.set()
                halted.set()
                history.append(dict(lane=lane, status='halted', column=current['status'],
                                    detail='skills-readiness: missing ' + ', '.join(e['name'] for e in boundary['entries'] if e['status'] == 'missing')))
                break
            process = None
            lock = inflight / str(card['number'])
            if live_lock(lock):
                halted.set()
                history.append(dict(lane=lane, status='halted', column=current['status'],
                                    detail=f'in-flight lock {lock}: another worker owns card #{card["number"]}; preserve it'))
                break
            try:
                process = subprocess.Popen(['bash', str(launcher), '--backend', backend, '--config', str(config_path),
                                            '--card', json.dumps(current), '--lane', lane, explicit[0],
                                            '--tier', args.tier] + (['--complexity', complexity] if complexity else []),
                                           stdout=subprocess.PIPE, text=True, start_new_session=True)
                active.add(process)
                lock.write_text(f'PID={process.pid}\nLANE={lane}\nBACKEND={backend}\nSTARTED={time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
            except OSError as error:
                if process is not None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    active.discard(process)
                history.append(dict(lane=lane, status='failed', column=current['status'],
                                    detail=f'could not start {lane} lane: {error}'))
                break
        preserve_lock = False
        try:
            stdout, _ = process.communicate()
            if process.returncode in (9, 10):
                preserve_lock = True
                (readiness_halted if process.returncode == 9 else skills_halted).set()
            try:
                result = json.loads(stdout)
                if (not isinstance(result, dict) or result.get('status') not in
                    ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']
                    or not all(isinstance(result.get(key), str) for key in ['column', 'detail'])):
                    raise ValueError('invalid lane result')
                if process.returncode and result['status'] != 'halted':
                    raise ValueError(f'lane exited {process.returncode}')
            except (ValueError, TypeError):
                result = dict(status='halted' if process.returncode in (9, 10, 79) or halted.is_set() else 'failed',
                              column=current['status'], detail=f'{lane} lane returned no valid result (exit {process.returncode})')
            with mutex:
                if result['status'] == 'halted':
                    halted.set()
                active.discard(process)
            history.append(dict(lane=lane, **result))
            if result['status'] != 'advanced':
                break
            expected = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane]
            if result['column'] != expected:
                history[-1].update(status='failed', detail=f'{lane} claimed advanced without reaching {expected}')
                break
            current['status'] = result['column']
            current.pop('lane', None)
        finally:
            try:
                if not preserve_lock and lock.read_text().startswith(f'PID={process.pid}\n'):
                    lock.unlink()
            except FileNotFoundError:
                pass
    last = history[-1]
    return dict(number=card['number'], finalStatus=last['status'], lastLane=last['lane'],
                column=last['column'], detail=last['detail'], prUrl=last.get('prUrl'),
                priorFindings=last.get('priorFindings'),
                lanesRun=' → '.join(f"{item['lane']}:{item['status']}" for item in history))

try:
    if backend == 'omp':
        omp_overlay(config)
        omp_limit(config, 'classify')
        omp_extension()
except (OSError, ValueError) as error:
    if marker.exists() and marker.read_text().strip() == owner:
        marker.unlink()
    parser.error(str(error))
try:
    with ThreadPoolExecutor(max_workers=workers) as pool:
        summaries = list(pool.map(run_card, cards))
    result = json.dumps(dict(cards=summaries, halted=halted.is_set()))
    if output_path:
        output = output_path
        temporary = output.with_name(output.name + f'.{owner}.tmp')
        temporary.write_text(result + '\n')
        temporary.replace(output)
    print(result)
finally:
    if marker.exists() and marker.read_text().strip() == owner:
        marker.unlink()
sys.exit(10 if skills_halted.is_set() else 9 if readiness_halted.is_set() else 79 if halted.is_set() else 0)
PY
