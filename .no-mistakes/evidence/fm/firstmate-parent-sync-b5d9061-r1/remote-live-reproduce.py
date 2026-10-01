import os, subprocess, pathlib, json, time, hashlib, signal
root=pathlib.Path.cwd()
scratch=root/'.test-remote-validation'
(scratch/'tmp').mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB')
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
base.update(HOME=str(scratch/'account'),TMPDIR=str(scratch/'tmp'),FM_ROOT_OVERRIDE=str(root),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
(scratch/'account').mkdir(exist_ok=True)
log=open(evidence/'remote-live-cli.log','w')
def emit(s):
 print(s,flush=True); log.write(s+'\n'); log.flush()
def run(args, env=None, ok=(0,), label=None):
 e=base.copy(); e.update(env or {})
 p=subprocess.run([str(x) for x in args],env=e,cwd=root,text=True,input='',capture_output=True,timeout=55)
 emit('$ '+(label or ' '.join(str(x) for x in args)))
 emit('exit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 assert p.returncode in ok,(args,p.returncode,p.stdout,p.stderr)
 return p

def home(name):
 h=scratch/name
 for d in ('state','data','config','projects'): (h/d).mkdir(parents=True,exist_ok=True)
 return h

def henv(h): return dict(FM_HOME=str(h))

# Real worker queue, real tracked command, no transport stub.
h=home('queue-home'); acct=scratch/'account'; queue=scratch/'queue'; empty=hashlib.sha256(b'').hexdigest(); status=h/'state/parent-replies.status'; status.write_text('')
env=base|dict(FM_HOME=str(h),FM_REMOTE_JOB_STATE_ROOT=str(queue))
worker_log=open(evidence/'remote-live-worker.log','w')
worker=subprocess.Popen([str(root/'bin/fm-remote-job-worker.sh')],env=env,cwd=root,stdout=worker_log,stderr=subprocess.STDOUT,start_new_session=True)
def stage(cmd,*args):
 s='. "$1/bin/fm-remote-job-lib.sh"; shift; fm_remote_job_stage "$HOME" "$FM_ROOT_OVERRIDE" "$FM_HOME" "$@"'
 return run(['bash','-c',s,'_',root,cmd,*args],env).stdout.strip()
def waitjob(j):
 s='. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_wait "$HOME" "$2" || exit; printf "job_exit=%s\\n" "$FM_REMOTE_JOB_EXIT"; cat "$FM_REMOTE_JOB_STDOUT"; cat "$FM_REMOTE_JOB_STDERR" >&2'
 return run(['bash','-c',s,'_',root,j],env).stdout
try:
 j=stage('fm-remote-delta-read.sh','state/parent-replies.status','0',empty,'15')
 time.sleep(.8)
 status.write_text('done [corr=0123456789abcdef]: partial')
 time.sleep(.8)
 assert (queue/'jobs'/j/'state').read_text().strip()!='done','partial line was published'
 emit('Before newline: queued delta read remains unfinished; complete-line contract held.')
 with status.open('a') as f:f.write(' reply\n')
 out=waitjob(j)
 assert 'job_exit=0' in out and 'status=delta' in out and 'partial reply' in out
 assert status.read_text()=='done [corr=0123456789abcdef]: partial reply\n'
 prefix=hashlib.sha256(status.read_bytes()).hexdigest(); offset=str(status.stat().st_size)
 poll=stage('fm-remote-delta-read.sh','state/parent-replies.status',offset,prefix,'30')
 for _ in range(100):
  if (queue/'jobs'/poll/'state').read_text().strip()=='running':break
  time.sleep(.05)
 cmd=stage('fm-contributions.sh','--help')
 assert 'job_exit=76' in waitjob(poll),'short command did not preempt long poll'
 assert 'captain|fleet|maintainer|nobody' in waitjob(cmd)
 retry=stage('fm-remote-delta-read.sh','state/parent-replies.status',offset,prefix,'10')
 with status.open('a') as f:f.write('note: after preemption\n')
 assert 'note: after preemption' in waitjob(retry)
 # Same-prefix mutation must be disclosed, not silently consumed.
 status.write_text('FAIL [corr=0123456789abcdef]: partial reply\nnote: after preemption\n')
 broken=run([root/'bin/fm-remote-delta-read.sh','state/parent-replies.status',offset,prefix,'0'],henv(h)).stdout
 assert 'status=continuity-broken' in broken and 'reason=prefix-changed' in broken
 emit('SCENARIO PASS: real queued delta read waits for complete lines, survives preemption, preserves source, and rejects prefix rewrites.')
finally:
 worker.terminate()
 try: worker.wait(timeout=12)
 except subprocess.TimeoutExpired: os.killpg(worker.pid,signal.SIGTERM);worker.wait(timeout=5)
 worker_log.close()

# Real drain presentation: remote route exclusion and same-name negative controls.
for kind in ('remote','main','local'):
 h=home('scan-'+kind)
 (h/'state/parent-replies.status').write_text('needs-decision [key=parent-only]: outbound parent question\n')
 (h/'state/real-task.status').write_text('needs-decision [key=real-task]: actual task choice\nnote: ready evidence\n')
 if kind!='main':
  (h/'.fm-secondmate-home').write_text('mate\n')
  binding='schema=fm-secondmate-parent.v1\nroute='+kind+'\n'
  binding+=('parent_host=disposable.invalid\n' if kind=='remote' else 'parent_home='+str(scratch/'scan-main')+'\n')
  (h/'.fm-secondmate-parent').write_text(binding)
 if kind=='remote':
  (h/'state/.status-presentation-cursor').write_text('parent-replies\tstrong:1:2:3\t99\t0\n')
  (h/'state/.parent-replies.open-decisions-cursor').write_text('needs-decision [key=old-phantom]: stale channel decision\n')
 p=run([root/'bin/fm-wake-drain.sh'],henv(h))
 (evidence/('remote-drain-'+kind+'.txt')).write_text(p.stdout+p.stderr)
 assert 'actual task choice' in p.stdout
 assert ('outbound parent question' in p.stdout)==(kind!='remote')
 if kind=='remote': assert 'parent-replies' not in p.stdout and 'old-phantom' not in p.stdout
emit('SCENARIO PASS: real wake-drain excludes only a remote mate outbound channel, discards stale channel presentation, and keeps main/local same-name task files.')

# Real installed backlog consumer.
h=home('backlog-home')
(h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
(h/'data/backlog.md').write_text('# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n')
for task in ('gerrit-done','gerrit-retained','github-control'):
 run(['tasks-axi','add',task,'Disposable closure proof','--kind','ship','--file',h/'data/backlog.md'],henv(h))
 run(['tasks-axi','start',task,'--file',h/'data/backlog.md'],henv(h))
s='. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_done "$FM_HOME/data" gerrit-done --pr https://gerrit.example.com/c/project/+/12345; fm_backlog_retain "$FM_HOME/data" gerrit-retained --pr https://gerrit.example.com/c/project/+/12345; fm_backlog_done "$FM_HOME/data" github-control --pr https://github.com/example/project/pull/7'
run(['bash','-ec',s,'_',root],henv(h))
for task in ('gerrit-done','gerrit-retained','github-control'):
 p=run(['tasks-axi','show',task,'--file',h/'data/backlog.md','--full'],henv(h))
 if task.startswith('gerrit'): assert 'Gerrit change https://gerrit.example.com/c/project/+/12345' in p.stdout
 if task=='gerrit-done': assert 'state: done' in p.stdout
 if task=='gerrit-retained': assert 'state: queued' in p.stdout
 if task=='github-control': assert 'pr:https://github.com/example/project/pull/7' in p.stdout
(evidence/'remote-backlog-persisted.md').write_text((h/'data/backlog.md').read_text())
emit('SCENARIO PASS: real tasks-axi closes Gerrit work with its change link in the body, retains unfinished decisions, and preserves normal GitHub PR links.')

# Real local verdict API; seeded owned observation, no forge call.
h=home('actor-home'); (h/'data/delivery').mkdir()
url='https://github.com/example/project/pull/7'; head='a'*40
(h/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] delivery - Disposable contribution '+url+' (repo: sample) (kind: ship)\n')
record={'schema':'fm-contributions.v1','task':'delivery','records':[{'url':url,'kind':'pr','checked_at':'2026-10-01T17:00:00Z','error':None,'pending':[],'seen':[],'verdict':None,'observation':{'head':head,'state':'open','draft':False,'mergeable':'mergeable','review_decision':'APPROVED','can_merge':False,'checks':[],'reviews':[],'events':[]}}]}
f=h/'data/delivery/contributions.json'; f.write_text(json.dumps(record))
args=[root/'bin/fm-contributions.sh','verdict','delivery',url,head,url+'#issuecomment-99']
before=f.read_bytes()
p=run([*args,'bogus','invalid actor'],henv(h),ok=(1,))
assert "invalid required actor 'bogus'; expected one of: captain, fleet, maintainer, nobody" in p.stderr
assert f.read_bytes()==before
accepted=[]
for actor in ('captain','fleet','maintainer','nobody'):
 run([*args,actor,'Documented actor'],henv(h))
 saved=json.loads(f.read_text())['records'][0]['verdict'];assert saved['actor']==actor and saved['head']==head;accepted.append(saved)
(evidence/'remote-contribution-verdicts.json').write_text(json.dumps(accepted,indent=2)+'\n')
emit('SCENARIO PASS: unknown actor is refused without mutation; all four documented actors persist exact judged head.')
log.close()
