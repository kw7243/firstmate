import hashlib,json,os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd()
base=root/'.no-mistakes/test-phase'
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3N97R1VEZ4XYMGAH1PPZ819')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'))}
env['TMPDIR']=str(base/'tmp')
env['FM_PROCEVENT_CLAIM_ROOT']=str(base/'live-claims')
log=(evidence/'product-transcript.log').open('w',buffering=1)
def emit(s):
    print(s,flush=True); log.write(s+'\n')
def run(script,*args,home=None,extra=None,expected=0,timeout=150,full=False):
    e=dict(env)
    if home:e['FM_HOME']=str(home)
    if extra:e.update(extra)
    command=['bash',str(root/'bin'/script),*map(str,args)]
    p=subprocess.run(command,env=e,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    emit('$ '+script+' '+' '.join(map(str,args))+'\nexit='+str(p.returncode))
    if full:
        path=evidence/(home.name+'-'+script.replace('.sh','')+('-reemit' if '--reemit' in args else '')+'.log')
        path.write_text(p.stdout)
        emit('full output: '+path.name)
        emit('\n'.join(line for line in p.stdout.splitlines() if any(s in line for s in ('lock:','error:','MISSING:','NETWORK_CHECKS:','READ-ONLY','SESSION_START_COMPLETION:','Startup remains incomplete','digest above is complete'))))
    else:emit(p.stdout.strip())
    if expected is not None: assert p.returncode==expected,(script,p.returncode,p.stdout)
    return p

def lab(name):
    home=base/name
    run('fm-lab-home.sh','create',home)
    (home/'config/backend').write_text('tmux\n')
    (home/'config/crew-harness').write_text('codex\n')
    return home

def wait_until(fn,seconds=20):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        value=fn()
        if value:return value
        time.sleep(.1)
    raise AssertionError('timed out waiting for product state')

results=[]
def scenario(name,func):
    emit('\nSCENARIO '+name)
    try:func(); results.append({'name':name,'result':'pass'})
    except Exception as e:
        emit('FAILED '+repr(e)); results.append({'name':name,'result':'fail','error':repr(e)})
    (evidence/'product-results.json').write_text(json.dumps(results,indent=2)+'\n')

home=lab('native-home')
def startup():
    p=run('fm-session-start.sh','--source','startup',home=home,full=True)
    assert 'READ-ONLY SESSION' not in p.stdout
    assert 'startup remains incomplete' not in p.stdout
    completion=home/'state/.session-start-complete'
    assert completion.is_file()
    before=completion.read_bytes()
    run('fm-startup-network.sh','wait','30',home=home,timeout=40)
    run('fm-startup-network.sh','report',home=home)
    run('fm-lock.sh','status',home=home)
    run('fm-lease.sh','claim','sample',home=home)
    assert ' live' in run('fm-lease.sh','check','sample',home=home).stdout
    run('fm-session-start.sh','--reemit',home=home,full=True)
    assert completion.read_bytes()==before
    assert ' live' in run('fm-lease.sh','check','sample',home=home).stdout
    run('fm-startup-network.sh','wait','30',home=home,timeout=40)
    run('fm-startup-network.sh','report',home=home)
    emit('Completion record preserved across reentry; existing task lease remains live.')
scenario('Native Codex startup, repeat entry, and lease continuity',startup)

def override():
    lock=home/'state/.lock'; record=home/'state/.lock-session'
    before=(lock.read_bytes(),record.read_bytes())
    p=run('fm-lock.sh',home=home,extra={'CODEX_THREAD_ID':'00000000-0000-4000-8000-000000000000'},expected=1)
    assert 'cannot verify the Codex tool session identity' in p.stdout
    assert (lock.read_bytes(),record.read_bytes())==before
    run('fm-lease.sh','claim','sample',home=home,extra={'FM_SUPERVISION_ACTOR':'branch'},expected=6)
    run('fm-lease.sh','release','sample',home=home)
    emit('Caller override and competing actor refused without changing ownership.')
scenario('Forged thread identity and competing lease actor are refused',override)

watchhome=lab('watch-home')
def watcher():
    out=(evidence/'watcher-process.log').open('w')
    e=dict(env,FM_HOME=str(watchhome),FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
    p=subprocess.Popen(['bash',str(root/'bin/fm-watch-arm.sh')],env=e,cwd=root,stdout=out,stderr=subprocess.STDOUT)
    namespace=watchhome/'state/.watch.lock/pid-namespace'
    saved=None
    try:
        wait_until(lambda: namespace.is_file() and (watchhome/'state/.last-watcher-beat').is_file())
        pid=int((watchhome/'state/.watch.lock/pid').read_text())
        saved=namespace.read_bytes()
        wait_until(lambda: 'watcher: started' in (evidence/'watcher-process.log').read_text())
        emit((evidence/'watcher-process.log').read_text().strip())
        namespace.write_text('foreign-process-namespace\n')
        p2=run('fm-watch-arm.sh','--restart',home=watchhome,expected=1)
        assert namespace.read_text()=='foreign-process-namespace\n'
        os.kill(pid,0)
        emit('Adversarial persisted namespace: restart refused; live watcher and lock preserved.')
        namespace.write_bytes(saved)
        run('fm-watch-arm.sh','--stop',home=watchhome)
        p.wait(timeout=15)
        emit('Original tracked arm exit='+str(p.returncode))
    finally:
        if saved is not None and namespace.is_file():namespace.write_bytes(saved)
        if p.poll() is None:
            run('fm-watch-arm.sh','--stop',home=watchhome,expected=None)
            try:p.wait(timeout=15)
            except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10)
        out.close()
scenario('Live watcher restart preserves an unqualified owner and cleanly stops after proof is restored',watcher)

pehome=lab('event-home')
def events():
    name='local-file-ready'; source='when-'+name
    trigger=pehome/'ready'
    claim=base/'live-claims'/(source+'.claim')
    original=None
    try:
        run('fm-procevent-when.sh','arm',name,'--interval','0.2','--stable','1','--deadline','120','--condition','/usr/bin/test','-f',trigger,'--action','/usr/bin/printf','captured-from-live-file-event\n',home=pehome)
        run('fm-procevent.sh','reconcile',home=pehome)
        wait_until(claim.is_file)
        original=claim.read_bytes()
        fields=original.decode().splitlines()
        assert len(fields)==13 and fields[-1]
        pid=int(fields[1]);os.kill(pid,0)
        run('fm-procevent.sh','list',home=pehome)
        emit('Claim contains process namespace and birth identity; source runner is alive.')
        fields[-1]='foreign-process-namespace'
        claim.write_text('\n'.join(fields)+'\n')
        unknown=claim.read_bytes()
        p=run('fm-procevent.sh','reconcile',home=pehome)
        assert 'uncertain=1' in p.stdout
        run('fm-procevent.sh','start',source,home=pehome,expected=None)
        p=run('fm-procevent.sh','retire',source,home=pehome,expected=None)
        assert p.returncode!=0
        assert claim.read_bytes()==unknown
        os.kill(pid,0)
        emit('Adversarial persisted namespace: reconcile/start/retire preserve the original runner and claim.')
        claim.write_bytes(original)
        trigger.touch()
        result=wait_until(lambda:next(iter((pehome/'state/procevent-inbox').glob(source+'.*.result')),None))
        text=result.read_text();emit('CAPTURED RESULT\n'+text)
        assert 'captured-from-live-file-event' in text
        assert 'fired' in run('fm-procevent.sh','classify',result,home=pehome).stdout
        seq=result.name[len(source)+1:-len('.result')]
        assert 'handled:' in run('fm-procevent.sh','handled',source,seq,home=pehome).stdout
        assert 'already-handled:' in run('fm-procevent.sh','handled',source,seq,home=pehome).stdout
        (evidence/'captured-event.result').write_bytes(result.read_bytes())
        run('fm-procevent-when.sh','retire',name,home=pehome)
    finally:
        if original and claim.is_file():claim.write_bytes(original)
        run('fm-procevent.sh','sweep-home',home=pehome,expected=None)
scenario('Real file event survives uncertain claim handling, captures output, and acknowledges idempotently',events)
emit('\nFINAL '+json.dumps(results))
log.close()
