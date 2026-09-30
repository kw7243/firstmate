import json,os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd(); base=root/'.no-mistakes/test-phase'; home=base/'paused-probe-home'
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3N97R1VEZ4XYMGAH1PPZ819')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'))}
env.update(FM_HOME=str(home),TMPDIR=str(base/'tmp'),FM_PROCEVENT_CLAIM_ROOT=str(base/'paused-claims'))
log=(evidence/'startup-refusal-transcript.log').open('w',buffering=1)
def say(s):print(s,flush=True);log.write(s+'\n')
def run(script,*args,expected=0,digest=None):
    p=subprocess.run(['bash',str(root/'bin'/script),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150)
    say('$ '+script+' '+' '.join(args)+'\nexit='+str(p.returncode))
    if digest:
        (evidence/digest).write_text(p.stdout)
        say('\n'.join(line for line in p.stdout.splitlines() if any(x in line for x in ('NETWORK_CHECKS:','SESSION_START_COMPLETION:','Startup remains incomplete','requested checks','MISSING:','digest above is complete','preserving the existing'))))
    else:say(p.stdout.strip())
    assert p.returncode==expected,(p.returncode,p.stdout)
    return p.stdout
run('fm-lab-home.sh','create',str(home))
(home/'config/backend').write_text('tmux\n')
(home/'config/crew-harness').write_text('codex\n')
run('fm-lock.sh')
run('fm-startup-network.sh','start','--locked','0','--harvest-pid','0')
status=home/'state/.startup-network.status'
def fields():return dict(x.split('=',1) for x in status.read_text().splitlines() if '=' in x)
record=fields(); assert record['state']=='running',record
pid=int(record['pid']); saved=None
try:
    os.kill(pid,signal.SIGSTOP)
    record=fields(); assert record['state']=='running',record
    saved=status.read_bytes()
    say('Paused the real deferred probe worker before publication.')
    status.write_text(saved.decode().replace('pid_namespace='+record['pid_namespace'],'pid_namespace=unverifiable-process-namespace'))
    unknown=status.read_bytes()
    text=run('fm-startup-network.sh','report')
    assert 'worker liveness is unknown' in text and 'stopped before publishing' not in text
    run('fm-startup-network.sh','start','--locked','1',expected=1)
    assert status.read_bytes()==unknown
    text=run('fm-session-start.sh','--source','startup',digest='incomplete-startup-digest.log')
    assert 'SESSION_START_COMPLETION: startup remains incomplete' in text
    assert 'dead-secondmate relaunch' in text
    assert 'The digest above is complete for this session start.' not in text
    assert not (home/'state/.session-start-complete').exists()
    assert status.read_bytes()==unknown
    os.kill(pid,0)
    say('Full startup visibly refused unscheduled phases; completion marker absent; original probe still alive.')
    status.write_bytes(saved)
    os.kill(pid,signal.SIGCONT)
    run('fm-startup-network.sh','wait','30')
    assert fields()['generation']==record['generation']
    run('fm-startup-network.sh','report')
    say('Original real probe published the same generation after ownership coordinates were restored.')
    text=run('fm-session-start.sh','--source','startup',digest='recovered-startup-digest.log')
    assert 'startup remains incomplete' not in text
    assert (home/'state/.session-start-complete').is_file()
    run('fm-startup-network.sh','wait','30')
    run('fm-startup-network.sh','report')
    say('PASS: full startup completed after the original probe published. Namespace uncertainty was injected into the persisted record; this is not real restricted-context proof.')
finally:
    if saved and fields().get('state')=='running':status.write_bytes(saved)
    try:os.kill(pid,signal.SIGCONT)
    except ProcessLookupError:pass
log.close()
