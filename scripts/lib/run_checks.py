#!/usr/bin/env python3
"""Run a project's declared checks in order and report pass / fail / skip with logs; exit code = failures.

Usage: run_checks.py CHECKS.json [--fast] [--logs DIR] [--receipts DIR] [--memo DIR] [--var name=value]...

CHECKS.json (schema 1):
  {"schema": 1,
   "checks": [
     {"name": "reconcile_modules", "run": ["python3", "scripts/reconcile_modules.py"]},
     {"name": "build_assetgraph", "run": ["${fontpy}", "scripts/build_assetgraph.py", "${pack}", "${logs}/graph.json", "--strict"],
      "requires": ["pack", "fontpy"]},
     {"name": "swift_test", "run": ["swift", "test"], "env": {"TYPING_TEST_PACK": "${pack}"}, "slow": true}
   ]}

  run        argv; "${name}" tokens are replaced from --var. A token that is exactly "${name}" and whose value holds
             spaces expands to several argv words (so fontpy="uv run --with fonttools python" works).
  requires   variables that must be non-empty, else the check is skipped with the variable's reason
             (from --var-reason name=text, default "no <name>").
  env        extra environment; entries whose expanded value is empty are left unset.
  slow       skipped when --fast is given.
  cwd        working directory relative to the checks file (default: its folder).

Dependencies are declared by the files themselves: a "${logs}/<file>" token names a file under the log folder; the first
check (in order) that mentions it writes it, every later check that mentions it reads it. A reader never runs when its
writer did not pass this run: it is skipped with "needs <writer> (<writer's state>)". So a reader of a slow writer skips
under --fast instead of failing on a missing file, and a writer is served from the memo only when every reader that will
run is served from the memo too (otherwise the writer runs again to produce the file).

A failing check never stops the later ones. Output is the same table for every project. No check's output is piped:
each exit code is read directly. Logs: one file per check under --logs (default: a fresh temporary folder).

--memo DIR remembers passes: a check whose inputs are unchanged since it last passed is reported "pass(memo)" and not
run. The key is the git tree hash of HEAD, the checks file's content, the check's declared run and env templates and
the values of the variables they reference (never `logs`, which differs per run); a dirty worktree (any uncommitted change) never reads or writes the memo, so a memo hit
always means "this exact committed tree passed this exact command". Failures are never remembered.

--receipts DIR writes one receipt per run, unconditionally: DIR/<UTC stamp>-<short tree sha>.json (schema 1: tree,
dirty, fast, startedAt, finishedAt, and one entry per declared check with name, status pass | pass(memo) | fail | skip,
reason, seconds, exit, log) and copies every per-check log into DIR/<same stem>/, so the facts of a gate run survive
the temporary log folder. The receipts folder itself never counts as dirtiness (for the memo or the receipt): a run
that writes a fact must not disable the memo by writing it. Without --receipts nothing changes.
"""
import argparse, hashlib, json, os, re, shlex, shutil, subprocess, sys, tempfile, time
from pathlib import Path

def git_output(cwd, *args):
    try: return subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True, check=True).stdout.strip()
    except Exception: return None

def utc(t=None): return time.strftime('%Y-%m-%dT%H%M%SZ', time.gmtime(t))

def is_dirty(cwd, exclude=None):
    """git status --porcelain is non-empty; paths under `exclude` (a folder) do not count."""
    args = ['status', '--porcelain']
    if exclude is not None:
        try: rel = os.path.relpath(Path(exclude).resolve(), Path(cwd).resolve())
        except ValueError: rel = None
        if rel and not rel.startswith('..'): args += ['--', '.', f':(exclude){rel}']
    out = git_output(cwd, *args)
    return out is None or out != ''

def expand(token, vars_):
    if token.startswith('${') and token.endswith('}') and token[2:-1] in vars_:
        return shlex.split(vars_[token[2:-1]]) if ' ' in vars_[token[2:-1]] else [vars_[token[2:-1]]]
    out = token
    for k, v in vars_.items(): out = out.replace('${' + k + '}', v)
    return [out]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('checks'); ap.add_argument('--fast', action='store_true'); ap.add_argument('--logs')
    ap.add_argument('--var', action='append', default=[]); ap.add_argument('--var-reason', action='append', default=[])
    ap.add_argument('--memo', help='folder that remembers passes per tree hash (clean worktrees only)')
    ap.add_argument('--receipts', help='folder that receives one receipt JSON per run plus a copy of the per-check logs')
    a = ap.parse_args()
    started = time.time()
    spec_path = Path(a.checks).resolve(); spec = json.loads(spec_path.read_text())
    if spec.get('schema') != 1: sys.exit(f'unsupported checks schema: {spec.get("schema")}')
    vars_ = dict(kv.split('=', 1) for kv in a.var)
    reasons = dict(kv.split('=', 1) for kv in a.var_reason)
    logs = Path(a.logs) if a.logs else Path(tempfile.mkdtemp(prefix='checks.'))
    logs.mkdir(parents=True, exist_ok=True); vars_['logs'] = str(logs)
    base = spec_path.parent
    tree = git_output(base, 'rev-parse', 'HEAD^{tree}')
    dirty = is_dirty(base, exclude=a.receipts)
    memo_dir = None
    if a.memo:
        clean = tree is not None and not dirty
        if clean:
            memo_dir = Path(a.memo); memo_dir.mkdir(parents=True, exist_ok=True)
        else:
            print('memo: worktree dirty or not a git repository; running every check')
    spec_hash = hashlib.sha256(spec_path.read_bytes()).hexdigest()
    checks = spec['checks']
    # ${logs}/<file> tokens: the first check that names a file writes it, later ones read it.
    def logs_files(c):
        toks = list(c['run']) + list((c.get('env') or {}).values())
        return {m for t in toks for m in re.findall(r'\$\{logs\}/([^\s"\']+)', t)}
    writer, needs = {}, {}
    for c in checks:
        for f in sorted(logs_files(c)):
            if f in writer:
                if writer[f] not in needs.setdefault(c['name'], []): needs[c['name']].append(writer[f])
            else: writer[f] = c['name']
    # Plan every check before running any: skip reason, memo file, memo hit.
    plan = {}
    for c in checks:
        name = c['name']; p = {'skip': None, 'memo_file': None, 'memo_hit': False}
        missing = [r for r in c.get('requires', []) if not vars_.get(r)]
        if c.get('slow') and a.fast: p['skip'] = '--fast'
        elif missing: p['skip'] = '; '.join(reasons.get(m, f'no {m}') for m in missing)
        p['cwd'] = base / c['cwd'] if c.get('cwd') else base
        if memo_dir is not None and p['skip'] is None:
            # The key uses the declared run/env templates plus the variable values they reference, except `logs`:
            # the log folder changes per run and must not defeat the memo.
            used = {k: v for k, v in vars_.items() if k != 'logs' and any('${' + k + '}' in t for t in list(c['run']) + list((c.get('env') or {}).values()))}
            key = hashlib.sha256(json.dumps({'tree': tree, 'spec': spec_hash, 'name': name, 'run': c['run'], 'cwd': str(p['cwd']),
                                             'envTemplate': c.get('env') or {}, 'vars': used}, sort_keys=True).encode()).hexdigest()
            p['memo_file'] = memo_dir / f'{name}.{key[:16]}.json'
            p['memo_hit'] = p['memo_file'].exists()
        plan[name] = p
    # A writer may be served from the memo only when every reader that will run is served from the memo too.
    changed = True
    while changed:
        changed = False
        for reader, writers in needs.items():
            if plan[reader]['skip'] or plan[reader]['memo_hit']: continue
            for w in writers:
                if plan[w]['memo_hit']: plan[w]['memo_hit'] = False; changed = True
    rows = []; failures = 0; state = {}
    for c in checks:
        name = c['name']; p = plan[name]
        if p['skip'] is not None:
            rows.append((name, 'skip', 0, p['skip'], None, f'skipped: {p["skip"]}')); state[name] = f'skipped: {p["skip"]}'; continue
        blocked = [w for w in needs.get(name, []) if not state.get(w, '').startswith('pass')]
        if blocked:
            why = '; '.join(f'needs {w} ({state.get(w, "not run")})' for w in blocked)
            rows.append((name, 'skip', 0, why, None, f'skipped: {why}')); state[name] = f'skipped: {why}'; continue
        if p['memo_hit']:
            rows.append((name, 'pass(memo)', 0, str(p['memo_file']), 0, f'passed earlier on tree {tree[:12]}: {p["memo_file"].name}')); state[name] = 'pass(memo)'; continue
        argv = [w for t in c['run'] for w in expand(t, vars_)]
        env = dict(os.environ)
        for k, v in (c.get('env') or {}).items():
            val = ''.join(expand(v, vars_)) if not (v.startswith('${') and v.endswith('}')) else vars_.get(v[2:-1], '')
            if val: env[k] = val
        cwd = p['cwd']
        log = logs / f'{name}.log'; start = time.time()
        with open(log, 'w') as fh:
            code = subprocess.run(argv, cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT).returncode
        secs = int(time.time() - start)
        if code == 0:
            rows.append((name, 'pass', secs, str(log), 0, 'exit 0')); state[name] = 'pass'
            if p['memo_file'] is not None:
                p['memo_file'].write_text(json.dumps({'check': name, 'tree': tree, 'passedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'seconds': secs, 'log': str(log)}, indent=2))
        else: rows.append((name, f'fail({code})', secs, str(log), code, f'exit {code}')); failures += 1; state[name] = f'fail({code})'
    print(f"\n{'CHECK':<24} {'STATE':<9} {'SEC':>6}  LOG")
    for name, state, secs, log, _, _ in rows: print(f'{name:<24} {state:<9} {secs:>6}  {log}')
    print(f'\n{failures} failure(s). Logs: {logs}')
    if a.receipts: print(f'Receipt: {write_receipt(a, rows, tree, dirty, started, logs)}')
    return failures

def write_receipt(a, rows, tree, dirty, started, logs):
    """One JSON per run plus a copy of the per-check logs; the receipt's `log` paths point at the copies."""
    out = Path(a.receipts); out.mkdir(parents=True, exist_ok=True)
    stem = f"{utc(started)}-{(tree or 'nogit')[:7]}"
    copies = out / stem; copies.mkdir(exist_ok=True)
    checks = []
    for name, state, secs, log, code, reason in rows:
        status = 'fail' if state.startswith('fail') else state
        kept = None
        if status in ('pass', 'fail') and Path(log).is_file():
            kept = copies / Path(log).name; shutil.copyfile(log, kept); kept = str(kept)
        checks.append({'name': name, 'status': status, 'reason': reason, 'seconds': secs, 'exit': code, 'log': kept})
    receipt = {'schema': 1, 'checks_file': str(Path(a.checks).resolve()), 'tree': tree, 'dirty': dirty, 'fast': bool(a.fast),
               'startedAt': utc(started), 'finishedAt': utc(), 'logs': str(copies), 'tmpLogs': str(logs),
               'summary': {k: sum(1 for c in checks if c['status'] == k) for k in ('pass', 'pass(memo)', 'fail', 'skip')},
               'checks': checks}
    path = out / f'{stem}.json'; path.write_text(json.dumps(receipt, indent=2) + '\n')
    return path

if __name__ == '__main__':
    sys.exit(main())
