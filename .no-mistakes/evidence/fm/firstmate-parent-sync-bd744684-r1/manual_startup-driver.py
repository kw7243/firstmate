import contextlib,os,pathlib,subprocess,time
root=pathlib.Path.cwd();scratch=root/'.test-watcher-validation';lab=scratch/'startup-lab-retry'; log=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2/startup-live-retry-transcript.log')
env=os.environ.copy()
for k in ['FM_ROOT','STATE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX_PANE','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
 env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),XDG_STATE_HOME=str(scratch/'xdg-state'),FM_PROCEVENT_CLAIM_ROOT=str(scratch/'startup-claims'),FM_BACKEND='tmux',TMUX='./.test-watcher-validation/private-no-server.sock,0,0',GH_CONFIG_DIR=str(scratch/'gh-no-credentials'),FM_STARTUP_NETWORK_TIMEOUT='30',FM_SESSION_START_TIMEOUT='15',FM_WEDGE_ALARM_EXEC='discard')
def run(args,check=True):
 t=time.monotonic();p=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=45);print('$ '+' '.join(map(str,args)));print(p.stdout+p.stderr,end='');print('exit='+str(p.returncode)+' elapsed='+str(round(time.monotonic()-t,3))+'s');
 if check and p.returncode:raise RuntimeError(str(args))
 return p

def text(p):return p.read_text() if p.exists() else ''
with log.open('w',buffering=1) as out,contextlib.redirect_stdout(out):
 print('Real deferred startup through fm-startup-network.sh and fm-bootstrap.sh, isolated empty lab, no mocked tools; GH_CONFIG_DIR empty and all credential tokens unset.')
 run(['bin/fm-lab-home.sh','create',str(lab)])
 rejected=run(['bin/fm-startup-network.sh','start','--locked','1','--harvest-pid','0'],False)
 assert rejected.returncode!=0
 assert not (lab/'state/.startup-network.status').exists()
 print('A locked-stage request without a verified home lock was rejected before a worker record was created.')
 run(['bin/fm-lock.sh'])
 run(['bin/fm-startup-network.sh','start','--locked','1','--harvest-pid','0'])
 print('Status immediately after start returned:\n'+text(lab/'state/.startup-network.status'))
 run(['bin/fm-startup-network.sh','wait','40'])
 report=run(['bin/fm-startup-network.sh','report'])
 assert 'completed off the startup path' in report.stdout and 'NEEDS_GH_AUTH' in report.stdout
 print('Published completion record:\n'+text(lab/'state/.startup-network.status'))
 assert 'phases=probe,sweeps' in text(lab/'state/.startup-network.status')
 end=time.monotonic()+15
 while 'startup-network' not in text(lab/'state/.wake-queue') and time.monotonic()<end:time.sleep(.1)
 print('Durable late actionable wake:\n'+text(lab/'state/.wake-queue'))
 assert 'startup-network' in text(lab/'state/.wake-queue')
 drain=run(['bin/fm-wake-drain.sh'])
 assert 'startup-network' in drain.stdout
 pidline=next(l for l in text(lab/'state/.startup-network.status').splitlines() if l.startswith('pid='))
 pid=int(pidline.split('=',1)[1]);deadline=time.monotonic()+15
 while pathlib.Path('/proc/'+str(pid)+'/stat').exists() and time.monotonic()<deadline:
  status=pathlib.Path('/proc/'+str(pid)+'/stat').read_text().rsplit(')',1)[1].split()[0]
  if status=='Z':break
  time.sleep(.1)
 proc=pathlib.Path('/proc/'+str(pid)+'/stat');status=proc.read_text().rsplit(')',1)[1].split()[0] if proc.exists() else 'gone'
 assert status in ['Z','gone'];print('Detached worker is no longer executing: '+status)
 print('RESULT: unowned mutating start refused; verified-owner deferred start returned during running state, completed probe+sweeps, retained isolated no-credentials diagnostic and queued it for the operator.')
print(log)
