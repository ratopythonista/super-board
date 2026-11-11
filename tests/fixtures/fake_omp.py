#!/usr/bin/env python3
# Stubbed `omp -p` for the offline OMP lane/wave suites; behaviour set by SB_OMP_TEST_* env vars.
import fcntl, json, os, re, sys, time
from pathlib import Path
args = sys.argv[1:]
prompt = args[-1] if args else ''
log_path = os.environ['SB_OMP_TEST_LOG']

def log(record):
    with open(log_path, 'a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(record) + '\n')

def flag(name):
    return args[args.index(name) + 1] if name in args else None

def bump(delta):
    counter = Path(log_path + '.active')
    counter.touch()
    with open(str(counter) + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = int(counter.read_text() or 0) + delta
        counter.write_text(str(value))
        return value

def result_path(text):
    match = re.search(r'write the JSON object \(no prose\) to (\S+)', text, re.I)
    if match:
        return Path(match.group(1))
    match = re.search(r'Write exactly .* to (\S+) and nothing else', text)
    return Path(match.group(1)) if match else None

def write_evidence(model=None):
    evidence = os.environ.get('SUPER_BOARD_LANE_MODEL_FILE')
    if evidence:
        Path(evidence).write_text(json.dumps(dict(role=model, provider='fake', model='fake-model',
                                                  thinking='low', tools=[])))
    sessions = flag('--session-dir')
    if sessions:
        session = Path(sessions)
        session.mkdir(parents=True, exist_ok=True)
        cost = float(os.environ.get('SB_OMP_TEST_COST', '0.125'))
        auxiliary = float(os.environ.get('SB_OMP_TEST_AUX_COST', '0.005'))
        with (session / 'fake-session.jsonl').open('w') as stream:
            stream.write(json.dumps({'type': 'message', 'message': {'role': 'assistant',
                                                                    'usage': {'cost': {'total': cost}}}}) + '\n')
            stream.write(json.dumps({'type': 'model_usage', 'role': 'judge',
                                     'usage': {'cost': {'total': auxiliary}}}) + '\n')

if 'Grade complexity' in prompt:
    target = result_path(prompt)
    log(dict(args=args, prompt=prompt, number=int(re.search(r'issue #(\d+)', prompt).group(1)),
             lane='grade', active=1, model=flag('--model'), tools=flag('--tools'),
             config=Path(flag('--config')).read_text() if flag('--config') else None))
    write_evidence(flag('--model'))
    if target:
        target.write_text(json.dumps(dict(complexity=os.environ.get('SB_OMP_TEST_GRADE', 'medium'))))
    sys.exit(int(os.environ.get('SB_OMP_TEST_GRADE_EXIT', '0')))

card = json.loads(re.search(r'^Card: (.+)$', prompt, re.M).group(1))
lane = re.search(r'Run super-(build|qa|review)', prompt).group(1)
active = bump(1)
log(dict(args=args, prompt=prompt, number=card['number'], lane=lane, active=active,
         model=flag('--model'), tools=flag('--tools'),
         config=Path(flag('--config')).read_text() if flag('--config') else None,
         env={key: os.environ.get(key) for key in
              ('SUPER_BOARD_RUN', 'SUPER_BOARD_LANE_ROLE', 'SUPER_BOARD_LANE_TOOLS',
               'SUPER_BOARD_LANE_MODEL_FILE', 'CLAUDE_PROJECT_DIR')}))
evidence = os.environ.get('SUPER_BOARD_LANE_MODEL_FILE')
if evidence:
    write_evidence(flag('--model'))
if os.environ.get('SB_OMP_TEST_DELAY'):
    time.sleep(float(os.environ['SB_OMP_TEST_DELAY']))
status = os.environ.get('SB_OMP_TEST_STATUS', 'advanced')
column = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane] if status == 'advanced' else card['status']
if os.environ.get('SB_OMP_TEST_RESULT'):
    result = os.environ['SB_OMP_TEST_RESULT']
elif os.environ.get('SB_OMP_TEST_INVALID'):
    result = 'not json'
else:
    result = json.dumps(dict(status=status, column=column, detail=os.environ.get('SB_OMP_TEST_DETAIL', 'stub lane result'),
                             prUrl=None, branch=None, priorFindings=None))
print(json.dumps({'type': 'message_start', 'message': {'role': 'assistant', 'content': []}}))
print(json.dumps({'type': 'message_end', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': result}]}}))
if os.environ.get('SB_OMP_TEST_TRAILING'):
    # An aborted `task` subagent can emit its own text after the main session ends.
    print(json.dumps({'type': 'message_end', 'message': {'role': 'assistant',
                                                         'content': [{'type': 'text', 'text': os.environ['SB_OMP_TEST_TRAILING']}]}}))
if not os.environ.get('SB_OMP_TEST_SKIP_FILE'):
    target = result_path(prompt)
    if target:
        target.write_text(result)
bump(-1)
if os.environ.get('SB_OMP_TEST_TIME'):
    print('Deadline exceeded: max-time reached', file=sys.stderr)
    sys.exit(1)
sys.exit(int(os.environ.get('SB_OMP_TEST_EXIT', '0')))
