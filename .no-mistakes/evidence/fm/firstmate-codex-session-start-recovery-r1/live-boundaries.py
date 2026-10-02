exec((__import__('pathlib').Path(__file__).parent/'live-startup.py').read_text().split('try:\n    text=run')[0])
try:
    state=LAB/'state'
    run('boundary-acquire',['bash','bin/fm-lock.sh'])
    before={x.name:x.read_bytes() for x in (state/'.lock',state/'.lock-session')}
    text=run('live-forged-descendant-identity',['bash','-c','export CODEX_THREAD_ID=00000000-0000-4000-8000-000000000000; bash bin/fm-lock.sh'],expect=1)
    assert 'cannot verify the Codex tool session identity' in text
    assert before=={x.name:x.read_bytes() for x in (state/'.lock',state/'.lock-session')}
    text=run('live-forged-hook-deferral',['bash','-c','export CODEX_THREAD_ID=00000000-0000-4000-8000-000000000000; bash bin/fm-sessionstart-run.sh --source compact'])
    assert 'Run `bin/fm-session-start.sh` now' in text
    assert before=={x.name:x.read_bytes() for x in (state/'.lock',state/'.lock-session')}
    for mutex in ('.wake-queue.lock','.watcher-down.lock'):
        lock=state/mutex
        lock.mkdir()
        (lock/'pid').write_text('999999999\n')
        (lock/'pid-namespace').write_text('foreign-boot/pid:[999999]\n')
        before={p.name:p.read_bytes() for p in lock.iterdir()}
        name='live-contention-'+mutex.strip('.')
        text=run(name,['bash','bin/fm-startup-network.sh','start','--locked','1','--harvest-pid','999999999'],extra={'FM_SESSION_START_TIMEOUT':'2','FM_STARTUP_NETWORK_TIMEOUT':'10'},expect=1,limit=20)
        assert results[-1]['elapsed_seconds']<12
        report=run(name+'-report',['bash','bin/fm-startup-network.sh','report'])
        assert 'NEEDS_GH_AUTH' in report and 'wake delivery failed within its budget' in report
        assert not (state/'.lock.acquire').exists() and not (state/'.startup-network.lock').exists()
        assert before=={p.name:p.read_bytes() for p in lock.iterdir()}
        shutil.rmtree(lock)
        for p in list(state.glob('.startup-network.*')):
            if p.is_file(): p.unlink()
    (LAB/'data/captain.md').write_text('Blocked-reader live fixture.\n'*65536)
    # The real local digest blocks while emitting fixture user data. No reader drains it.
    inner=LAB/'truncated-inner.py'
    inner.write_text('''import json,os,pathlib,signal,subprocess,time
home=pathlib.Path(os.environ['FM_HOME']); state=home/'state'
p=subprocess.Popen(['bash','bin/fm-session-start.sh'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
start=time.monotonic()
try:
 rc=p.wait(timeout=38)
 output=p.stdout.read().decode(errors='replace')
 (home/'truncated-captured.log').write_text(output)
 result={'exit':rc,'elapsed_seconds':round(time.monotonic()-start,2),'drained_bytes_after_return':len(output),'local_context_reached':'Blocked-reader live fixture.' in output,'network_status_exists':(state/'.startup-network.status').exists(),'completion_exists':(state/'.session-start-complete').exists(),'acquisition_claim_exists':(state/'.lock.acquire').exists(),'temporary_paths':list(str(p) for p in (home/'tmp').glob('fm-session-start-*'))}
 print(json.dumps(result,indent=2))
 assert rc==0 and not result['network_status_exists'] and not result['completion_exists'] and not result['acquisition_claim_exists'] and not result['temporary_paths']
finally:
 if p.poll() is None: os.killpg(p.pid,signal.SIGKILL); p.wait()
 p.stdout.close()
''')
    run('live-truncated-local-digest',['python3',str(inner)],extra={'FM_SESSION_START_TIMEOUT':'15'},limit=45)
    shutil.copy2(LAB/'truncated-captured.log',EVIDENCE/'live-truncated-captured.log')
finally:
    (EVIDENCE/'live-boundaries-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    print('disposable_lab_removed=true',flush=True)
