exec((__import__('pathlib').Path(__file__).parent/'live-startup.py').read_text().split('try:\n    text=run')[0])
holder=None
try:
    state=LAB/'state'
    text=run('live-host-native-identity',['bash','-c','set -eu; . bin/fm-session-lock-lib.sh; ! fm_session_lock_transient_codex; id=$(fm_session_lock_trusted_codex_session_id); printf "%s" "$id" | sha256sum; printf "context=persistent\n"'],sandbox=False)
    run('live-host-lock',['bash','bin/fm-lock.sh'],sandbox=False)
    holder=subprocess.Popen(['bash','-c','set -eu; . bin/fm-wake-lib.sh; fm_lock_try_acquire "$FM_HOME/state/.lock.acquire"; trap \'fm_lock_release "$FM_HOME/state/.lock.acquire"\' EXIT; touch "$FM_HOME/holder-ready"; while [ ! -f "$FM_HOME/holder-release" ]; do sleep .1; done'],cwd=CODE,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+8
    while not (LAB/'holder-ready').exists():
        assert time.monotonic()<deadline and holder.poll() is None
        time.sleep(.05)
    run('live-persistent-deferred-start',['bash','bin/fm-startup-network.sh','start','--locked','1','--harvest-pid','999999999'],sandbox=False)
    start_elapsed=results[-1]['elapsed_seconds']
    assert start_elapsed<3
    deadline=time.monotonic()+8
    while not (state/'.startup-network.status').exists():
        assert time.monotonic()<deadline
        time.sleep(.05)
    pending=(state/'.startup-network.status').read_text()
    assert 'state=running\n' in pending
    (LAB/'holder-release').touch()
    assert holder.wait(timeout=8)==0
    holder=None
    run('live-persistent-wait',['bash','bin/fm-startup-network.sh','wait','25'],sandbox=False)
    text=run('live-persistent-report',['bash','bin/fm-startup-network.sh','report'],sandbox=False)
    assert 'NEEDS_GH_AUTH' in text
    assert 'state=done\n' in (state/'.startup-network.status').read_text()
    # wait() can return after result publication, before fallback delivery settles.
    deadline=time.monotonic()+8
    while not (state/'.wake-queue').exists() or (state/'.lock.acquire').exists() or (state/'.startup-network.lock').exists():
        assert time.monotonic()<deadline
        time.sleep(.05)
    (EVIDENCE/'live-persistent-state.log').write_text('start_returned_seconds='+str(start_elapsed)+'\nSTATUS AT RETURN\n'+pending+'\nSTATUS AFTER RELEASE\n'+(state/'.startup-network.status').read_text()+'\nWAKE\n'+(state/'.wake-queue').read_text()+'\nacquisition_claim_absent=true\npublication_lock_absent=true\n')
    assert (state/'.wake-queue').read_text().count('startup-network:')==1
finally:
    if holder is not None:
        (LAB/'holder-release').touch()
        holder.communicate(timeout=8)
    (EVIDENCE/'live-persistent-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    print('disposable_lab_removed=true',flush=True)
