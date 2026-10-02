import hashlib, io, json, os, pathlib, shutil, subprocess, tarfile, tempfile, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3X7MZJANXVAHSVYGV3GR7YN')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-live-', dir=ROOT / '.test-tmp'))
subprocess.run(['bin/fm-lab-home.sh', 'create', str(LAB)], check=True, capture_output=True)
CODE = LAB / 'code'
CODE.mkdir()
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git', 'archive', 'HEAD']))) as archive:
    archive.extractall(CODE, filter='data')
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('NO_MISTAKES_GATE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'TMUX', 'HERDR_SESSION', 'HERDR_SESSION_ID', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID'):
        env.pop(key, None)
env.update(FM_HOME=str(LAB), HOME=str(LAB/'user'), GH_CONFIG_DIR=str(LAB/'gh'), TMPDIR=str(LAB/'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_SESSION_START_TIMEOUT='25', FM_STARTUP_NETWORK_TIMEOUT='15')
for name in ('user','gh','tmp'):
    (LAB/name).mkdir()
(LAB/'config/backend').write_text('tmux\n')
(LAB/'config/backlog-backend').write_text('manual\n')
(LAB/'config/supervision-host-off').touch()
subprocess.run(['git', 'init', '-q', str(CODE)], env=env, check=True)
results=[]
def run(name, args, *, sandbox=True, extra=None, limit=90, expect=0):
    e=env.copy()
    if extra:
        for k,v in extra.items():
            if v is None: e.pop(k,None)
            else: e[k]=v
    cmd=(['codex', 'sandbox', '-c', 'sandbox_mode="workspace-write"', '-c', 'sandbox_workspace_write.writable_roots='+json.dumps([str(LAB)])] if sandbox else [])+args
    started=time.monotonic()
    p=subprocess.run(cmd,cwd=CODE,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=limit)
    text=p.stdout.decode(errors='replace')
    (EVIDENCE/(name+'.log')).write_text(text)
    result={'name':name,'command':cmd,'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-started,2)}
    results.append(result)
    print(json.dumps(result), flush=True)
    assert p.returncode==expect, (result,text[-3000:])
    return text
try:
    text=run('live-native-identity',['bash','-c','. bin/fm-session-lock-lib.sh; fm_session_lock_transient_codex; id=$(fm_session_lock_trusted_codex_session_id) || exit; printf "%s" "$id" | sha256sum; printf "context=transient\n"'])
    assert 'context=transient' in text
    # Actual missing-proof Codex subprocess, without a fabricated executable or identity.
    for source in ('startup','new','clear','compact','resume','reload','fork','unknown'):
        text=run('live-hook-'+source,['bash','bin/fm-sessionstart-run.sh','--source',source],extra={'CODEX_THREAD_ID':None})
        assert 'Run `bin/fm-session-start.sh` now' in text, text
        assert not (LAB/'state/.lock').exists()
        assert not (LAB/'state/.startup-network.status').exists()
    text=run('live-direct-lock-refusal',['bash','bin/fm-lock.sh'],extra={'CODEX_THREAD_ID':None},expect=1)
    assert 'cannot verify the Codex tool session identity' in text
    text=run('live-transient-startup',['bash','bin/fm-sessionstart-run.sh','--source','startup'])
    assert 'FOREGROUND NETWORK CHECKS' in text and '●  STARTUP TRUNCATED' not in text and '●  READ-ONLY SESSION' not in text
    assert text.index('NEXT STEP') < text.index('FOREGROUND NETWORK CHECKS')
    state=LAB/'state'
    assert 'state=done\n' in (state/'.startup-network.status').read_text()
    assert not (state/'.lock.acquire').exists() and not (state/'.startup-network.lock').exists()
    assert (state/'.session-start-complete').read_text().strip()=='codex:'+os.environ['CODEX_THREAD_ID']
    assert (state/'.startup-network.delivered').exists()
    assert not (state/'.wake-queue').exists() or not (state/'.wake-queue').read_text()
    assert text.count('NEEDS_GH_AUTH')==1
    (EVIDENCE/'live-transient-state.log').write_text((state/'.startup-network.status').read_text()+'\nREPORT\n'+(state/'.startup-network.report').read_text()+'\ncompletion_matches_native_identity=true\nacquisition_claim_absent=true\npublication_lock_absent=true\ninline_acknowledged=true\nqueued_duplicate=false\n')
    before=(state/'.session-start-complete').read_bytes()
    text=run('live-transient-compact',['bash','bin/fm-sessionstart-run.sh','--source','compact'])
    assert 'CONTEXT RE-EMIT' in text and 'FOREGROUND NETWORK CHECKS' in text
    assert 'phases=probe\n' in (state/'.startup-network.status').read_text()
    assert (state/'.session-start-complete').read_bytes()==before
    # Unproved hook with an existing owner must still nudge and preserve the owner.
    lock_before={p.name:p.read_bytes() for p in (state/'.lock',state/'.lock-session',state/'.session-start-complete')}
    text=run('live-hook-existing-owner',['bash','bin/fm-sessionstart-run.sh','--source','compact'],extra={'CODEX_THREAD_ID':None})
    assert 'Run `bin/fm-session-start.sh` now' in text
    assert lock_before=={p.name:p.read_bytes() for p in (state/'.lock',state/'.lock-session',state/'.session-start-complete')}
    results.append({'name':'hook-existing-owner-preserved','pass':True})
finally:
    (EVIDENCE/'live-startup-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    print('disposable_lab_removed=true',flush=True)
