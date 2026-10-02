import fcntl, json, os, pathlib, select, signal, subprocess, time
home=pathlib.Path(os.environ['FM_HOME'])
state=home/'state'
read_fd,write_fd=os.pipe()
p=subprocess.Popen(['bash','bin/fm-session-start.sh','--source','startup'],stdin=subprocess.DEVNULL,stdout=write_fd,stderr=write_fd,start_new_session=True)
start=time.monotonic()
paused=False
observed=bytearray()
try:
    deadline=time.monotonic()+5
    while b'\nLOCK\n' not in observed:
        assert time.monotonic()<deadline, 'real inner digest did not start'
        if select.select([read_fd],[],[],.02)[0]:
            observed.extend(os.read(read_fd,4096))
    # Pause only the outer reporting parent while the real digest keeps running.
    os.kill(p.pid,signal.SIGSTOP)
    paused=True
    deadline=time.monotonic()+25
    while True:
        if select.select([read_fd],[],[],.05)[0]:
            observed.extend(os.read(read_fd,65536))
        requests=list((home/'tmp').glob('fm-session-start-foreground.*'))
        if requests and any(x.read_text().startswith('ready\n') for x in requests):
            while select.select([read_fd],[],[],.1)[0]:
                observed.extend(os.read(read_fd,65536))
            break
        assert p.poll() is None and time.monotonic()<deadline, 'real digest did not finish while parent paused'
    assert b'NEXT STEP' in observed
    assert b'FOREGROUND NETWORK CHECKS' not in observed
    assert not (state/'.startup-network.status').exists(), 'checks started before outer header'
    os.set_blocking(write_fd,False)
    filled=0
    try:
        while True: filled+=os.write(write_fd,b'x'*4096)
    except BlockingIOError: pass
    os.set_blocking(write_fd,True)
    os.kill(p.pid,signal.SIGCONT)
    paused=False
    result=p.wait(timeout=55)
    # Drain only after the whole command has returned.
    os.close(write_fd)
    write_fd=None
    while True:
        chunk=os.read(read_fd,65536)
        if not chunk: break
        observed.extend(chunk)
    (home/'blocked-output-captured.log').write_bytes(observed)
    status=(state/'.startup-network.status').read_text()
    report=(state/'.startup-network.report').read_text()
    wake=(state/'.wake-queue').read_text()
    result={'exit':result,'elapsed_seconds':round(time.monotonic()-start,2),'local_digest_completed_before_pipe_fill':True,'pipe_filled_bytes_before_outer_header':filled,'status':status,'retained_report':report,'delivered_marker_exists':(state/'.startup-network.delivered').exists(),'wake':wake,'acquisition_claim_exists':(state/'.lock.acquire').exists(),'publication_lock_exists':(state/'.startup-network.lock').exists(),'outer_temporary_paths':list(str(x) for x in (home/'tmp').glob('fm-session-start-*'))}
    print(json.dumps(result,indent=2),flush=True)
    assert result['exit']==0 and filled>0
    assert 'state=done\n' in status and 'NEEDS_GH_AUTH' in report
    assert not result['delivered_marker_exists'] and wake.count('startup-network:')==1
    assert not result['acquisition_claim_exists'] and not result['publication_lock_exists']
    assert not result['outer_temporary_paths']
finally:
    if p.poll() is None:
        if paused: os.kill(p.pid,signal.SIGCONT)
        os.killpg(p.pid,signal.SIGKILL)
        p.wait()
    os.close(read_fd)
    if write_fd is not None: os.close(write_fd)
