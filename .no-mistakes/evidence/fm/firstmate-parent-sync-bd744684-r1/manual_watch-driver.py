import os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd(); scratch=root/'.test-watcher-validation'; evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2'); lab=scratch/'watch-lab'; log=evidence/'watcher-live-transcript.log'; procs=[]
env=os.environ.copy()
for k in ['FM_ROOT','STATE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX_PANE','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN']:
 env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),XDG_STATE_HOME=str(scratch/'xdg-state'),FM_PROCEVENT_CLAIM_ROOT=str(scratch/'claims'),FM_BACKEND='tmux',TMUX='./.test-watcher-validation/private-no-server.sock,0,0',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_GUARD_GRACE='3',FM_WATCHER_STALL_BOUND='60',FM_ARM_CONFIRM_TIMEOUT='15',FM_ARM_ATTACH_POLL='0.1',FM_WEDGE_ALARM_EXEC='discard')
def run(args,check=True):
 r=subprocess.run(args,cwd=root,env=env,text=True,capture_output=True,timeout=40); print('$ '+' '.join(map(str,args))); print(r.stdout+r.stderr,end=''); print('exit='+str(r.returncode));
 if check and r.returncode: raise RuntimeError(str(args))
 return r

def waitfor(fn,seconds=30):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  if fn(): return
  time.sleep(.1)
 raise RuntimeError('condition did not become true')
def content(path):return path.read_text() if path.exists() else ''
def start(name):
 path=scratch/(name+'.out'); handle=path.open('w'); proc=subprocess.Popen([str(root/'bin/fm-watch-arm.sh')],cwd=root,env=env,stdout=handle,stderr=subprocess.STDOUT,text=True); handle.close();procs.append(proc);return proc,path
with log.open('w',buffering=1) as out:
 import contextlib
 with contextlib.redirect_stdout(out):
  try:
   print('Real Firstmate watcher + arm + durable drain; no mocked backend or product executable.')
   print('The tmux adapter points to a private absent socket; this home has no fleet panes.')
   run(['bin/fm-lab-home.sh','create',str(lab)])
   primary,primary_out=start('manual-arm-owning');waitfor(lambda:'watcher: started pid=' in content(primary_out))
   state=lab/'state'; holder=int((state/'.watch.lock/pid').read_text()); print('Owning arm: '+content(primary_out),end='')
   print('Actual watcher process and ownership record:')
   run(['ps','-p',str(holder),'-o','pid=,ppid=,stat=,comm='])
   for name in ['pid','pid-identity','pid-namespace','fm-home','watcher-path']:
    print(name+'='+content(state/'.watch.lock'/name).strip())
   attached,attached_out=start('manual-arm-attached');waitfor(lambda:'watcher: attached pid=' in content(attached_out))
   print('Attached arm: '+content(attached_out),end='')
   os.kill(holder,signal.SIGSTOP);print('Paused the real watcher to exceed its 3s freshness grace without reaching its 60s stall bound.')
   waitfor(lambda:time.time()-(state/'.last-watcher-beat').stat().st_mtime>=7,15)
   print('Beacon age='+str(int(time.time()-(state/'.last-watcher-beat').stat().st_mtime))+'s; attached_arm_returncode='+str(attached.poll()))
   assert attached.poll() is None
   os.kill(holder,signal.SIGCONT)
   (state/'demo.status').write_text('needs-decision: choose export format for live validation\n')
   print('Resumed real watcher and wrote a needs-decision status.')
   primary.wait(timeout=35);attached.wait(timeout=35)
   print('Owning arm output:\n'+content(primary_out));print('Attached arm output:\n'+content(attached_out))
   assert primary.returncode==0 and attached.returncode==0
   assert 'signal:' in content(primary_out) and 'signal:' in content(attached_out)
   print('Durable wake queue before any drain:\n'+content(state/'.wake-queue'))
   assert 'demo.status' in content(state/'.wake-queue')
   print('Unacknowledged watcher completion survives another arm:')
   recovery,recovery_out=start('manual-arm-recovery');recovery.wait(timeout=40)
   print(content(recovery_out));assert recovery.returncode==0;assert 'check:' in content(recovery_out) or 'signal:' in content(recovery_out)
   drain=run(['bin/fm-wake-drain.sh']);assert 'choose export format for live validation' in drain.stdout
   print('Durable queue after presentation:\n'+content(state/'.wake-queue'))
   import re
   ack=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',drain.stderr)
   if ack:run(['bin/fm-wake-drain.sh','--ack-through',ack.group(1),'--recovery-generation',ack.group(2)])
   print('Durable queue after exact acknowledgement:\n'+content(state/'.wake-queue'))
   print('Watch cycle lifecycle ledger:\n'+content(state/'.watch-cycle-exits.log'))
   print('RESULT: slow attached watcher preserved its cycle, delivered its real status to both arms, and rearm recovered durable unacknowledged work.')
  finally:
   try:os.kill(holder,signal.SIGCONT)
   except (NameError,ProcessLookupError):pass
   if lab.exists():run(['bin/fm-watch-arm.sh','--stop'],check=False)
   for p in procs:
    if p.poll() is None:p.terminate()
    try:p.wait(timeout=15)
    except subprocess.TimeoutExpired:p.kill();p.wait()
   print('All owned watcher/arm processes reaped.')
print(log)
