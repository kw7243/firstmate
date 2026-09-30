import os,pathlib,subprocess,time
os.umask(0o077)
root=pathlib.Path.cwd();base=root/'.no-mistakes/test-phase';home=base/'event-home'
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3N97R1VEZ4XYMGAH1PPZ819')
(home/'state').chmod(0o700)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'))}
env.update(FM_HOME=str(home),TMPDIR=str(base/'tmp'),FM_PROCEVENT_CLAIM_ROOT=str(base/'live-claims'))
log=(evidence/'event-transcript.log').open('w',buffering=1)
def say(s):print(s,flush=True);log.write(s+'\n')
def run(script,*args,expected=0):
    p=subprocess.run(['bash',str(root/'bin'/script),*map(str,args)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
    say('$ '+script+' '+' '.join(map(str,args))+'\nexit='+str(p.returncode)+'\n'+p.stdout.strip())
    if expected is not None:assert p.returncode==expected,(p.returncode,p.stdout)
    return p

def until(fn):
    end=time.monotonic()+30
    while time.monotonic()<end:
        value=fn()
        if value:return value
        time.sleep(.1)
    raise AssertionError('timeout waiting for product state')
name='local-file-ready';source='when-'+name;trigger=home/'ready';claim=base/'live-claims'/(source+'.claim');original=None
try:
    run('fm-procevent-when.sh','arm',name,'--interval','0.2','--stable','1','--deadline','120','--condition','/usr/bin/test','-f',trigger,'--action','/usr/bin/printf','%s\\n','captured-from-live-file-event')
    run('fm-procevent.sh','reconcile')
    until(claim.is_file)
    original=claim.read_bytes();fields=original.decode().splitlines()
    assert len(fields)==13 and fields[-1]
    pid=int(fields[1]);os.kill(pid,0)
    run('fm-procevent.sh','list')
    say('Claim has namespace and process birth identity; original runner alive.')
    fields[-1]='foreign-process-namespace';claim.write_text('\n'.join(fields)+'\n');unknown=claim.read_bytes()
    p=run('fm-procevent.sh','reconcile');assert 'uncertain=1' in p.stdout
    run('fm-procevent.sh','start',source,expected=None)
    p=run('fm-procevent.sh','retire',source,expected=None);assert p.returncode!=0
    assert claim.read_bytes()==unknown;os.kill(pid,0)
    say('Injected unverifiable namespace: no replacement, no claim deletion, no signal to original runner.')
    claim.write_bytes(original);trigger.touch()
    result=until(lambda:next(iter((home/'state/procevent-inbox').glob(source+'.*.result')),None))
    text=result.read_text();say('CAPTURED RESULT\n'+text)
    assert 'captured-from-live-file-event' in text
    assert 'fired' in run('fm-procevent.sh','classify',result).stdout
    seq=result.name[len(source)+1:-len('.result')]
    assert 'handled:' in run('fm-procevent.sh','handled',source,seq).stdout
    assert 'already-handled:' in run('fm-procevent.sh','handled',source,seq).stdout
    (evidence/'captured-event.result').write_bytes(result.read_bytes())
    run('fm-procevent-when.sh','retire',name)
    say('PASS: real condition/action and durable capture; guarded namespace state was synthetic, not actual cross-context proof.')
finally:
    if original and claim.is_file():claim.write_bytes(original)
    run('fm-procevent.sh','sweep-home',expected=None)
log.close()
