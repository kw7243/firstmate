import os, pathlib, subprocess, shutil, json, hashlib
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB')
scratch=root/'.test-resume-gerrit'
assert not scratch.exists()
scratch.mkdir()
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'BD_'))}
base.update(HOME=str(scratch/'account'), TMPDIR=str(scratch/'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
for name in ('account','tmp','code'): (scratch/name).mkdir()
log=(ev/'resume-gerrit-live.log').open('w')
def run(args, env=None, cwd=root, accepted=(0,)):
    proc=subprocess.run(list(map(str,args)),env=base|dict(env or {}),cwd=cwd,text=True,capture_output=True,timeout=150)
    log.write('$ '+' '.join(map(str,args))+'\nexit='+str(proc.returncode)+'\n'+proc.stdout+proc.stderr+'\n');log.flush()
    print('exit='+str(proc.returncode)+' '+' '.join(map(str,args[:3])),flush=True)
    assert proc.returncode in accepted, proc.stdout+proc.stderr
    return proc.stdout
try:
    # Execute only the two changed Gerrit lifecycle cases, with existing fixtures.
    archive=scratch/'code.tar'
    with archive.open('wb') as out: subprocess.run(['git','archive','HEAD'],cwd=root,stdout=out,check=True)
    subprocess.run(['tar','-xf',str(archive),'-C',str(scratch/'code')],check=True)
    rel='tests/fm-captain-hold-lifecycle.test.sh'
    original=(scratch/'code'/rel).read_text()
    prefix=original.split('\ntest_uninventoried_report_decision_refuses_completion\n')[0]+'\n'
    selected=['test_answer_before_cleanup_replay_notes_a_retained_gerrit_change','test_teardown_retains_a_gerrit_captain_call_with_its_change_url']
    assert prefix!=original and all(name+'()' in prefix for name in selected)
    (scratch/'code'/rel).write_text(prefix+'\n'.join(selected)+'\n')
    proc=subprocess.run([str(scratch/'code/bin/fm-test-run.sh'),'--jobs','1','--json',str(ev/'resume-gerrit-regression-timing.json'),rel],cwd=scratch/'code',env=base,text=True,capture_output=True,timeout=240)
    (ev/'resume-gerrit-regressions.log').write_text(proc.stdout+proc.stderr)
    assert proc.returncode==0, proc.stdout+proc.stderr
    # Live local public CLI: no fake dependency or forge involved.
    lab=scratch/'lab'
    run([root/'bin/fm-lab-home.sh','create',lab])
    (lab/'.tasks.toml').write_text((root/'.tasks.toml').read_text())
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    env={'FM_HOME':str(lab)}
    task='gerrit-answer'
    url='https://gerrit.example.com/c/project/+/12345'
    run(['tasks-axi','add',task,'Disposable retained Gerrit decision','--kind','ship','--start'],env,cwd=lab)
    run([root/'bin/fm-captain-hold.sh','hold',task,'--reason','Choose the disposable follow-up'],env)
    # Create the persisted recovery contract via its real production writer.
    command='. "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_close_marker_write "$FM_HOME/state" gerrit-answer "$FM_HOME/data" fixture-gerrit --retain --pr "$2"'
    run(['bash','-ec',command,'_',root,url],env)
    before=run(['tasks-axi','show',task,'--full'],env,cwd=lab)
    assert 'hold_kind: captain' in before
    decision=lab/'answer.txt';decision.write_text('Proceed with the landed change.\n')
    run([root/'bin/fm-captain-hold.sh','answer',task,'--decision-file',decision],env)
    after=run(['tasks-axi','show',task,'--full'],env,cwd=lab)
    assert 'state: done' in after and 'Gerrit change '+url in after and 'Proceed with the landed change.' in after
    saved=(lab/'data/backlog.md').read_bytes()
    run([root/'bin/fm-captain-hold.sh','answer',task,'--decision-file',decision],env)
    assert (lab/'data/backlog.md').read_bytes()==saved
    (ev/'resume-gerrit-answered-backlog.md').write_bytes(saved)
    log.write('SCENARIO PASS: real answer CLI closes a retained Gerrit call, preserves its change URL and exact answer, and is idempotent.\n')
finally:
    log.close()
    shutil.rmtree(scratch)
