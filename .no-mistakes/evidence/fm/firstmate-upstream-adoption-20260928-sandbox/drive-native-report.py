import os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd();base=root/'.no-mistakes/test-phase';home=base/'native-report-home'
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3N97R1VEZ4XYMGAH1PPZ819');log=(evidence/'native-cross-namespace-report.log').open('w',buffering=1)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'))}
env.update(FM_HOME=str(home),TMPDIR=str(base/'tmp'),FM_PROCEVENT_CLAIM_ROOT=str(base/'report-claims'))
def say(s):print(s,flush=True);log.write(s+'\n')
def run(script,*args,sandbox=False):
    cmd=['bash',str(root/'bin'/script),*map(str,args)]
    if sandbox:cmd=['codex','sandbox',*cmd]
    p=subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=50)
    say('$ '+('codex sandbox ' if sandbox else '')+script+' '+' '.join(map(str,args))+'\nexit='+str(p.returncode)+'\n'+p.stdout.strip())
    assert p.returncode==0,(p.returncode,p.stdout)
    return p.stdout
run('fm-lab-home.sh','create',home)
run('fm-lock.sh')
run('fm-startup-network.sh','start','--locked','0','--harvest-pid','0')
status=home/'state/.startup-network.status'
record=dict(s.split('=',1) for s in status.read_text().splitlines() if '=' in s)
assert record['state']=='running';pid=int(record['pid'])
os.kill(pid,signal.SIGSTOP)
try:
    before=status.read_bytes()
    assert b'state=running' in before
    say('Paused actual host worker to make in-flight reporting observable; no persisted coordinates changed.')
    text=run('fm-startup-network.sh','report',sandbox=True)
    assert 'worker liveness is unknown' in text and 'stopped before publishing' not in text and 'rerun ' not in text
    assert status.read_bytes()==before
    say('Actual native sandbox reports unknown; host generation record unchanged.')
finally:os.kill(pid,signal.SIGCONT)
run('fm-startup-network.sh','wait','30')
assert dict(s.split('=',1) for s in status.read_text().splitlines() if '=' in s)['generation']==record['generation']
run('fm-startup-network.sh','report',sandbox=True)
say('PASS: original generation published and its completed report is readable from the native sandbox.')
log.close()
