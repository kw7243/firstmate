import os, pathlib, subprocess, time, tempfile, signal, shutil, json, re
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.test-inbox-validation'))
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','NO_MISTAKES_GATE']:
    env.pop(key,None)
env['FM_HOME']=str(lab)
processes=[]; sock=None

def cmd(args,check=True,**kwargs):
    p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kwargs)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
    return p

def tm(*a,**kw): return cmd(['tmux','-L','fm-lab',*a],**kw)
def waitfor(pred,seconds=15):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if pred(): return
        time.sleep(.01)
    raise RuntimeError('Condition did not occur within '+str(seconds)+'s')
def lib(code,*args):
    return cmd(['bash','-c','. "$1/bin/fm-task-inbox-lib.sh"; shift; '+code,'_',root,*args])
def start_send(n,paused=False):
    log=open(ev/f'inbox-live-send-{n}.log','w')
    p=subprocess.Popen([str(root/'bin/fm-send.sh'),'retry','--fire-and-forget',f'{n:016x}',f'Isolated validation: only append the line message-{n} to {lab}/acted.txt, then move this message into handled/. Do no other repository work or supervision.'],env={**env,'FM_TASK_INBOX_LOCK_WAIT_SECS':'0'},stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    processes.append(p)
    if paused:
        rec=lab/f'state/retry.inbox/{n:03d}.msg'
        waitfor(lambda:rec.exists() and not os.path.lexists(lab/'state/.meta-retry.lock'))
        os.killpg(p.pid,signal.SIGSTOP)
        assert p.poll() is None
        print(f'sender-{n}: paused after durable enqueue and metadata unlock',flush=True)
    return p

def complete(p,n):
    assert p.wait(timeout=20)==0, (n,(ev/f'inbox-live-send-{n}.log').read_text())
    print(f'sender-{n}: '+(ev/f'inbox-live-send-{n}.log').read_text().splitlines()[-1],flush=True)
try:
    print(cmd([root/'bin/fm-lab-home.sh','create',lab]).stdout.strip(),flush=True)
    sock=cmd([root/'bin/fm-lab-home.sh','tmux-dir',lab]).stdout.strip();env['TMUX_TMPDIR']=sock
    (lab/'config/backend').write_text('tmux\n'); (lab/'config/backlog-backend').write_text('manual\n');(lab/'config/wait-no-turns').touch()
    inbox=lab/'state/retry.inbox';(inbox/'handled').mkdir(parents=True)
    tm('new-session','-d','-s','primary','-n','fm-retry','-x','220','-y','50','-c',str(root),'-e',f'FM_HOME={lab}','-e','FM_TASK_ID=retry','-e',f'FM_TASK_INBOX={inbox}','codex','--dangerously-bypass-approvals-and-sandbox','--disable','hooks','-c','check_for_update_on_startup=false')
    env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    time.sleep(8)
    screen=tm('capture-pane','-p','-t','primary').stdout
    (ev/'inbox-retry-startup.txt').write_text(screen)
    assert 'Update now' not in screen and 'Do you trust' not in screen
    (lab/'state/retry.meta').write_text(f'window=primary:fm-retry\nkind=secondmate\nharness=codex\nbackend=tmux\nhome={lab}\n')
    tm('send-keys','-t','primary','-l','Unsubmitted draft preserved by validation')
    state=lib('fm_backend_composer_state tmux primary:fm-retry fm-retry').stdout
    print('real composer state with draft:',state,flush=True); assert state.strip()=='pending'
    # The real sender must wait for post-enqueue bookkeeping even with a zero enqueue budget.
    p=start_send(1,True)
    holder=subprocess.Popen(['bash','-c','. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_lock_acquire "$2/state/retry.inbox/.seq.lock" || exit 1; touch "$2/locked"; while [ ! -e "$2/release" ]; do sleep 0.05; done; fm_lock_release "$2/state/retry.inbox/.seq.lock"','_',str(root),str(lab)],env=env,start_new_session=True)
    processes.append(holder); waitfor(lambda:(lab/'locked').exists())
    os.killpg(p.pid,signal.SIGCONT); time.sleep(1)
    assert p.poll() is None and not (inbox/'.retry-ring').exists()
    print('sender-1: remains waiting while real inbox lock is held despite FM_TASK_INBOX_LOCK_WAIT_SECS=0',flush=True)
    (lab/'release').touch(); assert holder.wait(timeout=10)==0;complete(p,1)
    assert (inbox/'.retry-ring').read_text().strip()=='001.msg'
    # Complete a newer send ahead of an older, already enqueued one.
    p=start_send(2,True); q=start_send(3);complete(q,3)
    assert (inbox/'.retry-ring').read_text().strip()=='003.msg'
    os.killpg(p.pid,signal.SIGCONT);complete(p,2)
    assert (inbox/'.retry-ring').read_text().strip()=='003.msg'
    print('out-of-order unhandled send: marker stays 003.msg',flush=True)
    p=start_send(4,True);q=start_send(5);complete(q,5)
    (inbox/'004.msg').rename(inbox/'handled/004.msg')
    os.killpg(p.pid,signal.SIGCONT);complete(p,4)
    assert (inbox/'.retry-ring').read_text().strip()=='005.msg'
    print('out-of-order acknowledged send: marker stays 005.msg',flush=True)
    (lab/'state/retry.status').write_text('needs-decision [key=live-check]: waiting for this isolated decision\n')
    watchenv={**env,'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_TASK_INBOX_GRACE_SECS':'1'}
    w=None
    wlog=open(ev/'inbox-retry-watch.log','w')
    def ensure_watch():
        global w
        if w is not None and w.poll() is None:return
        drain=cmd([root/'bin/fm-wake-drain.sh'],check=False).stdout
        print('WATCHER DRAIN\n'+drain,flush=True)
        ack=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through (\d+) --recovery-generation ([\w.-]+)',drain)
        if ack:
            print(cmd([root/'bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]]).stdout,flush=True)
        w=subprocess.Popen([str(root/'bin/fm-watch.sh')],env=watchenv,stdout=wlog,stderr=subprocess.STDOUT,start_new_session=True);processes.append(w)
    def pump(seconds,done=lambda:False):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            ensure_watch()
            if done():return True
            time.sleep(.2)
        return done()
    pump(12)
    assert (inbox/'.retry-ring').read_text().strip()=='005.msg' and not (lab/'acted.txt').exists()
    assert w.poll() is None, 'watcher did not remain running during decision hold'
    print('open own decision: running watcher leaves retry owed and draft untouched',flush=True)
    with (lab/'state/retry.status').open('a') as f:f.write('resolved [key=live-check]: cleared for delivery\n')
    tm('send-keys','-t','primary','C-u')
    delivered=pump(150,lambda:all((inbox/f'handled/{n:03d}.msg').exists() for n in [1,2,3,5]))
    if not delivered:
        print('FAILED DELIVERY SCREEN\n'+tm('capture-pane','-p','-t','primary').stdout,flush=True)
        print('DUE ACTION: '+lib('FM_TASK_INBOX_GRACE_SECS=1 fm_task_inbox_due_action "$FM_HOME/state" retry').stdout,flush=True)
        print('AGENT STATE: '+lib('fm_backend_agent_state tmux primary:fm-retry').stdout,flush=True)
        print('COMPOSER STATE: '+lib('fm_backend_composer_state tmux primary:fm-retry fm-retry').stdout,flush=True)
        print((lab/'state/.watch-triage.log').read_text() if (lab/'state/.watch-triage.log').exists() else 'no triage log',flush=True)
        raise RuntimeError('No acknowledgement after supervised watcher restart/ack loops')
    time.sleep(4)
    screen=tm('capture-pane','-p','-S','-200','-t','primary').stdout
    (ev/'inbox-retry-final.txt').write_text(screen)
    result={'acted':(lab/'acted.txt').read_text(),'handled':[p.name for p in sorted((inbox/'handled').glob('*.msg'))],'retry_marker_exists':(inbox/'.retry-ring').exists(),'watcher_log':(lab/'state/.watch-triage.log').read_text() if (lab/'state/.watch-triage.log').exists() else ''}
    print(json.dumps(result,indent=2),flush=True)
    assert result['acted'].splitlines()==['message-1','message-2','message-3','message-5']
    assert not result['retry_marker_exists']
    (ev/'inbox-live-retry-state.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    for p in processes:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGCONT);os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    if sock:tm('kill-server',check=False)
    cmd([root/'bin/fm-lab-home.sh','teardown',lab],check=False)
    shutil.rmtree(lab)
