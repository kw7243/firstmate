import contextlib,os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd();scratch=root/'.test-watcher-validation';lab=scratch/'stall-lab';log=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2/watcher-live-stall.log');procs=[];holder=None
env=os.environ.copy()
for k in ['FM_ROOT','STATE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX_PANE']:
 env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),XDG_STATE_HOME=str(scratch/'xdg-state'),FM_PROCEVENT_CLAIM_ROOT=str(scratch/'claims'),FM_BACKEND='tmux',TMUX='./.test-watcher-validation/private-no-server.sock,0,0',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_GUARD_GRACE='3',FM_WATCHER_STALL_BOUND='10',FM_ARM_CONFIRM_TIMEOUT='10',FM_ARM_ATTACH_POLL='0.1',FM_WEDGE_ALARM_EXEC='discard')
def run(args,check=True):
 p=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=20);print('$ '+' '.join(map(str,args)));print(p.stdout+p.stderr,end='');print('exit='+str(p.returncode));
 if check and p.returncode:raise RuntimeError(str(args))
 return p

def text(p):return p.read_text() if p.exists() else ''
def waitfor(fn,seconds=25):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  if fn():return
  time.sleep(.1)
 raise RuntimeError('wait timed out')
def start(name):
 p=scratch/(name+'.out');f=p.open('w');proc=subprocess.Popen([str(root/'bin/fm-watch-arm.sh')],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT);f.close();procs.append(proc);return proc,p
with log.open('w',buffering=1) as out,contextlib.redirect_stdout(out):
 try:
  print('Real watcher and arm; hard-stall boundary using SIGSTOP against our own recorded child process.')
  run(['bin/fm-lab-home.sh','create',str(lab)])
  owner,owner_out=start('stall-owner');waitfor(lambda:'watcher: started pid=' in text(owner_out));holder=int((lab/'state/.watch.lock/pid').read_text());print(text(owner_out),end='')
  attached,attached_out=start('stall-attached');waitfor(lambda:'watcher: attached pid=' in text(attached_out));print(text(attached_out),end='')
  os.kill(holder,signal.SIGSTOP);print('Paused actual watcher pid='+str(holder))
  attached.wait(timeout=30);print('Attached arm terminal output:\n'+text(attached_out));print('Attached arm exit='+str(attached.returncode));assert attached.returncode!=0;assert 'at or past hard bound 10s' in text(attached_out)
  ps=run(['ps','-p',str(holder),'-o','pid=,stat=,comm=']);assert 'T' in ps.stdout
  print('Actual holder remains stopped and alive: attached arm reported failure without signaling it.')
  print('Cycle ledger:\n'+text(lab/'state/.watch-cycle-exits.log'));assert 'reason=attached-holder-stalled' in text(lab/'state/.watch-cycle-exits.log')
  print('RESULT: hard-bound stall has an explicit nonzero failure and classified lifecycle record.')
 finally:
  if holder:
   try:os.kill(holder,signal.SIGCONT)
   except ProcessLookupError:pass
  if lab.exists():run(['bin/fm-watch-arm.sh','--stop'],False)
  for p in procs:
   if p.poll() is None:p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
  print('All owned watcher/arm processes stopped and reaped.')
print(log)
