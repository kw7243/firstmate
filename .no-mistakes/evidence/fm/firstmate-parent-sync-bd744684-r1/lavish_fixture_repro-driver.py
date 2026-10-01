import contextlib,os,pathlib,subprocess,time
os.umask(0o022)
root=pathlib.Path.cwd();base=root/'.test-watcher-validation/lavish-repro-retry';base.mkdir();home=base/'home';state=base/'state';state.mkdir();(home/'data').mkdir(parents=True);source=base/'lavish-source.sh';trigger=base/'result-ready';source.write_text('#!/usr/bin/env bash\nwhile [ ! -e "$1" ]; do sleep 0.05; done\nprintf "session:\\n  status: feedback\\n  session_ended: true\\nprompts[1]{tag,prompt}:\\n  feedback,\\\"real review result\\\"\\n"\n');source.chmod(0o755)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'):env.pop(k,None)
env.update(FM_ROOT_OVERRIDE=str(root),FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_PROCEVENT_CLAIM_ROOT=str(base/'claims'),HOME=str(root/'.test-watcher-validation/home'),TMPDIR=str(root/'.test-watcher-validation/tmp'),FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS='1')
def run(args,check=True):
 t=time.monotonic();r=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=25);print('$ '+' '.join(map(str,args)));print(r.stdout+r.stderr,end='');print('exit='+str(r.returncode)+' elapsed='+str(round(time.monotonic()-t,3)));
 if check and r.returncode:raise RuntimeError(str(args))
 return r
log=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2/lavish-fixture-repro-retry.log')
with log.open('w',buffering=1) as out,contextlib.redirect_stdout(out):
 try:
  run(['bin/fm-procevent.sh','register','lavish','idle-lavish','--',str(source),str(trigger)])
  r=run(['bin/fm-procevent.sh','reconcile'],False)
  run(['bin/fm-procevent.sh','list'])
  time.sleep(3)
  run(['bin/fm-procevent.sh','list'])
  if r.returncode:
   print('Attached start exposes the detached runner diagnostic:')
   p=subprocess.Popen(['bin/fm-procevent.sh','start','idle-lavish'],cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
   time.sleep(2);trigger.touch();s,_=p.communicate(timeout=20);print(s);print('attached exit='+str(p.returncode))
  else:trigger.touch();time.sleep(2)
 finally:run(['bin/fm-procevent.sh','retire','idle-lavish'],False)
print(log)
