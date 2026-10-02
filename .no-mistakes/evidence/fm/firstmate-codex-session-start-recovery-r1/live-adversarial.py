# Reuse the disposable home setup and actual-product launcher from live-startup.py.
exec((__import__('pathlib').Path(__file__).parent/'live-startup.py').read_text().split('try:\n    text=run')[0])
try:
    state=LAB/'state'
    run('adversarial-acquire',['bash','bin/fm-lock.sh'])
    unknown='state=running\npid=999999999\npid_namespace=foreign-boot/pid:[999999]\npid_starttime=1\nlocked=1\nphases=probe,sweeps\ngeneration=unknown-generation\n'
    (state/'.startup-network.status').write_text(unknown)
    text=run('live-unknown-worker',['bash','bin/fm-session-start.sh'])
    assert (state/'.startup-network.status').read_text()==unknown
    assert not (state/'.session-start-complete').exists()
    assert 'startup remains incomplete' in text
    (state/'.startup-network.status').unlink()
    claim=state/'.lock.acquire'
    claim.mkdir()
    (claim/'pid').write_text('999999999\n')
    (claim/'pid-namespace').write_text('foreign-boot/pid:[999999]\n')
    before={x.name:x.read_bytes() for x in claim.iterdir()}
    text=run('live-foreign-claim-refusal',['bash','bin/fm-lock.sh'],expect=1,limit=10)
    assert before=={x.name:x.read_bytes() for x in claim.iterdir()}
    assert results[-1]['elapsed_seconds']<5
    shutil.rmtree(claim)
    # A real process holds the acquisition claim through the worker's deadline.
    text=run('live-stage-lock-deadline',['bash','-c','set -eu; . bin/fm-wake-lib.sh; fm_lock_try_acquire "$FM_HOME/state/.lock.acquire"; trap \'fm_lock_release "$FM_HOME/state/.lock.acquire"\' EXIT; FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=3 bash bin/fm-startup-network.sh start --locked 1 --harvest-pid 0 && exit 99; cat "$FM_HOME/state/.startup-network.status"; bash bin/fm-startup-network.sh report'],limit=20)
    assert 'state=failed' in text and 'at its deadline' in text
    assert not claim.exists() and not (state/'.startup-network.lock').exists()
    # Fresh state for the genuine full-digest stopped-reader proof.
    for p in list(state.glob('.startup-network.*'))+[state/'.wake-queue',state/'.wake-queue.seq']:
        if p.is_file(): p.unlink()
    inner=LAB/'blocked-output-inner.py'
    shutil.copy2(EVIDENCE/'blocked-output-inner.py',inner)
    text=run('live-blocked-before-header',['python3',str(inner)],extra={'FM_SESSION_START_TIMEOUT':'15','FM_STARTUP_NETWORK_TIMEOUT':'10'},limit=85)
    shutil.copy2(LAB/'blocked-output-captured.log',EVIDENCE/'live-blocked-output-captured.log')
    # Human-consumable report after the output transport starts draining again.
    run('live-retained-report-after-block',['bash','bin/fm-startup-network.sh','report'])
finally:
    (EVIDENCE/'live-adversarial-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    print('disposable_lab_removed=true',flush=True)
