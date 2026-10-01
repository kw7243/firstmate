import contextlib,io,os,pathlib,subprocess,tarfile,time
root=pathlib.Path.cwd();scratch=root/'.test-watcher-validation';lab=scratch/'fresh-primary-lab-retry';log=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2/sessionstart-live-retry-transcript.log')
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_ROOT','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID']):env.pop(k,None)
for k in ['NO_MISTAKES_GATE','STATE','TMUX_PANE','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_PID','CLAUDE_CODE_SESSION_ID']:
 env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(scratch/'sessionstart-user-home'),TMPDIR=str(scratch/'tmp'),XDG_STATE_HOME=str(scratch/'sessionstart-xdg-state'),XDG_CONFIG_HOME=str(scratch/'sessionstart-xdg-config'),FM_PROCEVENT_CLAIM_ROOT=str(scratch/'sessionstart-claims'),FM_BACKEND='tmux',TMUX='./.fm-lab-private-absent.sock,0,0',GH_CONFIG_DIR=str(scratch/'sessionstart-gh-no-credentials'),FM_STARTUP_NETWORK_TIMEOUT='45',FM_SESSION_START_TIMEOUT='90',FM_WEDGE_ALARM_EXEC='discard',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live validation fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Live validation fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
pathlib.Path(env['HOME']).mkdir(parents=True,exist_ok=True)
def run(args,check=True,cwd=lab,timeout=110):
 t=time.monotonic();p=subprocess.run(args,cwd=cwd,env=env,capture_output=True,text=True,timeout=timeout);print('$ '+' '.join(map(str,args)));print(p.stdout+p.stderr,end='');print('exit='+str(p.returncode)+' elapsed='+str(round(time.monotonic()-t,3))+'s');
 if check and p.returncode:raise RuntimeError(str(args))
 return p

def text(p):return p.read_text() if p.exists() else ''
def wait_worker():
 status=lab/'state/.startup-network.status'
 if not status.exists():return
 run(['bin/fm-startup-network.sh','wait','60'],False,timeout=70)
 s=text(status);print('Final deferred worker record:\n'+s)
 pidline=next((x for x in s.splitlines() if x.startswith('pid=')),None)
 if not pidline:return
 pid=int(pidline.split('=',1)[1]);deadline=time.monotonic()+95
 while time.monotonic()<deadline:
  proc=pathlib.Path('/proc')/str(pid)/'stat'
  st=proc.read_text().rsplit(')',1)[1].split()[0] if proc.exists() else 'gone'
  if st in ['gone','Z']:print('Deferred worker no longer executing: '+st);return
  time.sleep(.1)
 raise RuntimeError('Deferred worker did not exit after publication/harvest')
with log.open('w',buffering=1) as out,contextlib.redirect_stdout(out):
 print('Real fresh-primary sessionstart CLI from exact HEAD snapshot under actual current Codex ancestry. No new vendor CLI or tmux server is launched. No test seam or gate bypass.')
 run(['bin/fm-lab-home.sh','create',str(lab)],cwd=root)
 head=run(['git','rev-parse','HEAD'],cwd=root).stdout.strip()
 archive=subprocess.run(['git','archive','--format=tar',head],cwd=root,env=env,capture_output=True,check=True).stdout
 with tarfile.open(fileobj=io.BytesIO(archive),mode='r:') as tf:tf.extractall(lab,filter='data')
 run(['git','init','-q','-b','main'])
 run(['git','add','-A'])
 run(['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','commit','-qm','Disposable live-validation snapshot'])
 (lab/'config/supervision-host-off').touch()
 (lab/'state').rmdir();print('Fresh snapshot source HEAD='+head+'; state directory absent='+str(not (lab/'state').exists()))
 try:
  startup=run(['bin/fm-sessionstart-run.sh','--source','startup'])
  assert (lab/'state').is_dir()
  assert (lab/'state/.session-start-complete').is_file()
  assert 'LOCK' in startup.stdout and 'NETWORK CHECKS' in startup.stdout
  first=(lab/'state/.session-start-complete').read_text();print('State created by the real wrapper; startup completion record:\n'+first)
  deferred_before=text(lab/'state/.startup-network.status')
  generation_before=next(l for l in deferred_before.splitlines() if l.startswith('generation='))
  compact=run(['bin/fm-sessionstart-run.sh','--source','compact'])
  assert 're-emit' in compact.stdout.lower() or 'reemit' in compact.stdout.lower() or 'already held' in compact.stdout.lower()
  assert (lab/'state/.session-start-complete').read_text()==first
  generation_after=next(l for l in text(lab/'state/.startup-network.status').splitlines() if l.startswith('generation='))
  assert 'locked=0' in text(lab/'state/.startup-network.status')
  assert 'phases=probe\n' in text(lab/'state/.startup-network.status')
  print('Compact retained completion and scheduled only the read-only auth probe: '+generation_after)
  print('RESULT: fresh primary wrapper created absent state, acquired its native Codex session lock, completed the startup digest, and compact re-emitted with a read-only probe and no repeated mutating sweeps.')
 finally:wait_worker()
print(log)
