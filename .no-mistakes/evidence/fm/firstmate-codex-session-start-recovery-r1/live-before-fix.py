import pathlib
common=(pathlib.Path(__file__).parent/'live-startup.py').read_text().split('try:\n    text=run')[0]
exec(common.replace("['git', 'archive', 'HEAD']", "['git', 'archive', 'ee473a7']"))
try:
    text=run('before-fix-unproved-hook',['bash','bin/fm-sessionstart-run.sh','--source','startup'],extra={'CODEX_THREAD_ID':None})
    assert '●  READ-ONLY SESSION' in text and 'cannot verify the Codex tool session identity' in text
    assert 'Run `bin/fm-session-start.sh` now' not in text
    inner=(EVIDENCE/'blocked-output-inner.py').read_text()
    before_wait=inner.split('    result=p.wait(timeout=55)')[0]
    cleanup=inner.split('finally:\n    if p.poll() is None:')[1]
    negative=before_wait+'''    try:
        p.wait(timeout=20)
        raise AssertionError('previous revision unexpectedly returned before reader drained')
    except subprocess.TimeoutExpired:
        assert not (state/'.startup-network.status').exists()
        assert not (state/'.session-start-complete').exists()
        print(json.dumps({'revision':'ee473a7','elapsed_seconds':round(time.monotonic()-start,2),'local_digest_completed_before_pipe_fill':True,'pipe_filled_bytes_before_outer_header':filled,'outer_still_blocked_beyond_15s_budget':True,'checks_never_started':True,'completion_absent':True},indent=2),flush=True)
finally:
    if p.poll() is None:'''+cleanup
    path=LAB/'before-fix-inner.py'
    path.write_text(negative)
    text=run('before-fix-blocked-before-header',['python3',str(path)],extra={'FM_SESSION_START_TIMEOUT':'15','FM_STARTUP_NETWORK_TIMEOUT':'10'},limit=60)
finally:
    (EVIDENCE/'before-fix-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    print('disposable_lab_removed=true',flush=True)
