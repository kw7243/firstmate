from pathlib import Path
import json, os, shlex, shutil, subprocess
ROOT = Path.cwd()
EVIDENCE = Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2')
SCRATCH = ROOT / '.test-main' / 'live'
SCRATCH.mkdir(parents=True)
ENV = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('GIT_CONFIG_') or k in ('TMUX','TYPESAFE_API_KEY','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
ENV.update(HOME=str(SCRATCH/'user'), TMPDIR=str(ROOT/'.test-main/tmp'), XDG_STATE_HOME=str(SCRATCH/'user/state'), XDG_CONFIG_HOME=str(SCRATCH/'user/config'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Validation User',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation User',GIT_COMMITTER_EMAIL='validation@example.invalid')
Path(ENV['HOME']).mkdir()
log=(EVIDENCE/'git-dispatch-live.log').open('w')
def run(args,cwd=ROOT, extra=None,expect=0):
    env=ENV| (extra or {})
    log.write('$ '+shlex.join([str(a) for a in args])+'\n')
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=env,capture_output=True,text=True,timeout=40)
    log.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n')
    log.flush()
    assert p.returncode==expect, (args,p.returncode,p.stdout,p.stderr)
    return p
try:
    run(['git','--version'])
    repo=SCRATCH/'repo'
    run(['git','init','-q',repo])
    run(['git','commit','--allow-empty','-qm','Initial fixture'],repo)
    marker=repo/'repository-hook-ran'
    hook=repo/'.git/hooks/pre-commit'
    hook.write_text('#!/bin/sh\nprintf "repository hook ran\\n" > repository-hook-ran\nexit 37\n')
    hook.chmod(0o700)
    hooks=SCRATCH/'launch-hooks'
    run([ROOT/'bin/fm-git-strip-ai-trailers.sh','install',hooks,repo])
    pane={'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'core.hooksPath','GIT_CONFIG_VALUE_0':str(hooks)}
    run(['git','config','core.hooksPath',''],repo)
    p=run(['git','commit','--allow-empty','-m','Empty hooksPath remains usable','--trailer','Co-authored-by: Cursor <cursoragent@cursor.com>','--trailer','Co-authored-by: Jane Doe <jane@example.invalid>'],repo,pane)
    assert not p.stderr and not marker.exists()
    msg=run(['git','show','-s','--format=%an <%ae>%n%B'],repo).stdout
    assert 'Cursor' not in msg and 'Jane Doe <jane@example.invalid>' in msg and 'Validation User' in msg
    log.write('Observed: commit created with human attribution preserved, AI attribution stripped, no repository hook run, and empty stderr.\n')
    head=run(['git','rev-parse','HEAD'],repo).stdout
    run(['git','config','core.hooksPath','~fm-no-such-user-6171/hooks'],repo)
    p=run([hooks/'pre-commit'],repo,pane,expect=1)
    assert p.stderr.count('failed to expand user dir')==1 and 'refusing to skip its pre-commit hook' in p.stderr
    run(['git','config','--file',repo/'.git/config','--unset-all','core.hooksPath'],repo)
    assert run(['git','rev-parse','HEAD'],repo).stdout==head
    log.write('Observed: malformed path refused by installed wrapper, diagnostic emitted exactly once, HEAD unchanged after restoration.\n')
    p=run(['git','commit','--allow-empty','-m','Should be rejected by repository hook'],repo,pane,expect=1)
    assert marker.read_text()=='repository hook ran\n' and run(['git','rev-parse','HEAD'],repo).stdout==head
    log.write('Repository hook marker: '+marker.read_text())
    log.write('Observed: configured repository hook still ran and blocked the commit.\n')
    home=SCRATCH/'home'
    (home/'config').mkdir(parents=True)
    (home/'state').mkdir()
    (home/'data').mkdir()
    brief=home/'brief.md'
    brief.write_text('# Task\nValidate local provider configuration.\n')
    rules=home/'config/crew-dispatch.json'
    rules.write_text(json.dumps({'rules':[{'when':'x','use':[{'harness':'opencode'},{'harness':'rovo'},{'harness':'codex'}]}],'default':[{'harness':'pi'},{'harness':'claude'}]}))
    fm={'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_CONFIG_OVERRIDE':str(home/'config'),'FM_DATA_OVERRIDE':str(home/'data')}
    # This inert value reaches only local configuration validation, which must refuse before any API call.
    p=run([ROOT/'bin/fm-dispatch-resolve.sh',brief],extra=fm|{'TYPESAFE_API_KEY':'local-preflight-only'},expect=2)
    assert len(p.stderr.splitlines())==1 and all(x in p.stderr for x in ('provider: opencode','provider: rovo','provider: pi'))
    assert 'Broken pipe' not in p.stderr and not p.stdout
    p=run([ROOT/'bin/fm-dispatch-resolve.sh',brief],extra=fm)
    assert 'dispatch-resolve: off' in p.stderr and not p.stdout
    log.write('Observed: all ambiguous providers reported in one diagnostic; absent opt-in key leaves dispatch off.\n')
    quota=home/'quota.json'
    quota.write_text(json.dumps({'generatedAt':'2030-01-01T00:00:00Z','schemaVersion':5,'providers':[{'provider':'codex','state':{'status':'fresh'},'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':75,'runway':{'status':'through_reset'}}]}}]}))
    p=run([ROOT/'bin/fm-quota-choose.sh','--snapshot',quota,'--candidate','codex:gpt-test'],extra=fm)
    assert p.stdout=='codex gpt-test\n' and not p.stderr
    p=run([ROOT/'bin/fm-quota-choose.sh','--snapshot',quota,'--candidate','claude:model-test'],extra=fm,expect=1)
    assert p.stdout=='none\n'
    log.write('Observed: local snapshot selects measured positive quota and refuses unmeasured provider.\n')
finally:
    for path,dirs,files in os.walk(SCRATCH):
        os.chmod(path,0o700)
    shutil.rmtree(SCRATCH)
    log.write('Cleanup: fixture repositories, hooks and homes removed.\n')
    log.close()
