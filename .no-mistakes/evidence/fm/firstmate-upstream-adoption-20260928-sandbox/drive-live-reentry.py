import os,pathlib,signal,subprocess,threading,time
root=pathlib.Path.cwd();base=root/'.no-mistakes/test-phase';home=base/'native-home';ev=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3N97R1VEZ4XYMGAH1PPZ819')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'))}
env.update(FM_HOME=str(home),TMPDIR=str(base/'tmp'),FM_PROCEVENT_CLAIM_ROOT=str(base/'reentry-claims'))
log=(ev/'live-sweep-reentry.log').open('w',buffering=1)
def say(s):print(s,flush=True);log.write(s+'\n')
def run(script,*args):
    p=subprocess.run(['bash',str(root/'bin'/script),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150)
    say('$ '+script+' '+' '.join(args)+'\nexit='+str(p.returncode))
    assert p.returncode==0,p.stdout
    return p.stdout
run('fm-lock.sh')
run('fm-startup-network.sh','start','--locked','1','--harvest-pid','0')
status=home/'state/.startup-network.status';mutex=home/'state/.lock.acquire/pid'
record=dict(s.split('=',1) for s in status.read_text().splitlines() if '=' in s);pid=int(record['pid'])
end=time.monotonic()+10
while time.monotonic()<end:
    if mutex.is_file() and mutex.read_text().strip()==str(pid):break
    time.sleep(.01)
else:raise AssertionError('worker never held mutation lease')
os.kill(pid,signal.SIGSTOP)
say('Paused real deferred sweep while it holds the session acquisition claim.')
before=(home/'state/.lock-session').read_bytes()
timer=threading.Timer(12,lambda:os.kill(pid,signal.SIGCONT));timer.start()
try:
    start=time.monotonic();text=run('fm-session-start.sh','--reemit');elapsed=time.monotonic()-start
    (ev/'live-sweep-reentry-digest.log').write_text(text)
    assert 'READ-ONLY SESSION' not in text and 'STARTUP TRUNCATED' not in text
    assert (home/'state/.lock-session').read_bytes()==before
    say(f'Reentry completed after {elapsed:.2f}s with the same verified session, no read-only fallback and no truncated startup.')
    assert elapsed>=10
finally:
    timer.cancel()
    try:os.kill(pid,signal.SIGCONT)
    except ProcessLookupError:pass
run('fm-startup-network.sh','wait','30')
say(run('fm-startup-network.sh','report'))
say('PASS: same-session native Codex reentry succeeds across a real sweep lasting beyond the former 10-second cutoff.')
log.close()
