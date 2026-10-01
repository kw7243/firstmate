from pathlib import Path
import copy, json, os, shlex, shutil, subprocess
root=Path.cwd()
evidence=Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2')
fixture=root/'.test-main/contributions-live'
fixture.mkdir(parents=True)
os.umask(0o077)
for name in ('user','home/data','home/state','home/config','home/projects','deny-forge'):
 (fixture/name).mkdir(parents=True)
home=fixture/'home'
(home/'config/backlog-backend').write_text('manual\n')
(home/'.tasks.toml').write_text((root/'.tasks.toml').read_text())
url='https://github.com/example/fixture/pull/8'
(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n'+''.join(f'- [ ] {task} - Contribution {url} (repo: sample) (kind: ship)\n' for task in ('terminal','duplicate','late')))
terminal={'url':url,'kind':'pr','checked_at':'2026-09-16T08:00:00Z','error':None,'pending':[],'seen':[],'notified':[],'verdict':None,'observation':{'head':'b'*40,'state':'merged','draft':False,'mergeable':'mergeable','review_decision':'APPROVED','can_merge':False,'checks':[],'reviews':[],'events':[]}}
duplicate=copy.deepcopy(terminal)
duplicate.update(checked_at='2026-09-15T08:00:00Z',error='previous failed observation',pending=[{'token':'evt-retained'}],notified=['evt-previous'])
duplicate['observation'].update(head='a'*40,state='open')
for task,row in [('terminal',terminal),('duplicate',duplicate)]:
 (home/'data'/task).mkdir()
 (home/'data'/task/'contributions.json').write_text(json.dumps({'schema':'fm-contributions.v1','task':task,'records':[row]}))
# These tripwires must never execute: terminal convergence is an offline path.
for tool in ('gh','gh-axi'):
 p=fixture/'deny-forge'/tool
 p.write_text('#!/bin/sh\nprintf "unexpected forge read\\n" >> "$FM_HOME/forge-called"\nexit 91\n')
 p.chmod(0o700)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
env.update(HOME=str(fixture/'user'),PATH=str(fixture/'deny-forge')+':'+os.environ['PATH'],TMPDIR=str(root/'.test-main/tmp'),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),FM_CONTRIBUTIONS_NOW='2026-10-01T00:00:00Z',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
with (evidence/'contributions-live.log').open('w') as log:
 def run(args):
  log.write('$ '+shlex.join([str(a) for a in args])+'\n')
  p=subprocess.run([str(a) for a in args],env=env,cwd=root,text=True,capture_output=True,timeout=45)
  log.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n');log.flush()
  assert p.returncode==0,(args,p.stdout,p.stderr)
  return p
 try:
  log.write('Persisted records before polling:\n'+json.dumps({'terminal':terminal,'duplicate':duplicate,'late':'no record'},indent=2)+'\n')
  p=run([root/'bin/fm-fleet-snapshot.sh','--contribution-input'])
  owned=json.loads(p.stdout)
  p=run([root/'bin/fm-contributions.sh','poll'])
  assert not p.stdout and not p.stderr and not (home/'forge-called').exists()
  before={}
  for task in ('terminal','duplicate','late'):
   path=home/'data'/task/'contributions.json'
   row=json.loads(path.read_text())['records'][0]
   log.write(f'Persisted {task} after poll:\n'+json.dumps(row,indent=2)+'\n')
   assert row['observation']==terminal['observation'] and row['error'] is None and row['checked_at']==terminal['checked_at']
   if task=='duplicate': assert row['pending']==duplicate['pending'] and row['notified']==duplicate['notified']
   if task=='late': assert row['pending']==[] and row['notified']==[]
   before[task]=path.read_bytes()
  run([root/'bin/fm-contributions.sh','poll'])
  for task in before: assert (home/'data'/task/'contributions.json').read_bytes()==before[task]
  assert not (home/'forge-called').exists()
  q=home/'state/.wake-queue'
  assert not q.exists() or not q.read_bytes()
  log.write('Observed: all three owners retain the known terminal result; prior pending/notification state survives; repeated polling makes no forge calls and queues no new wake.\n')
 finally:
  shutil.rmtree(fixture)
  log.write('Cleanup: isolated home and records removed.\n')
