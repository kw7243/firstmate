import hashlib,json,os,pathlib,shutil,subprocess,tarfile,tempfile,time
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB')
scratch=pathlib.Path(tempfile.mkdtemp(prefix='.test-supervision-tail-',dir=root))
code=scratch/'code';code.mkdir()
tmp=scratch/'tmp';tmp.mkdir()
try:
    archive=scratch/'head.tar'
    with archive.open('wb') as f:subprocess.run(['git','archive','HEAD'],check=True,stdout=f)
    with tarfile.open(archive) as a:a.extractall(code,filter='data')
    original=(code/'tests/fm-supervision-host.test.sh').read_text()
    boundary='\ntest_park_exit_probe_uses_half_second_child_sleeps\n'
    definitions,calls=original.split(boundary,1)
    all_calls=['test_park_exit_probe_uses_half_second_child_sleeps']+calls.strip().splitlines()
    prior='test_return_during_an_engine_turn_hands_its_outcomes_to_main'
    clocks={'test_park_boundary_ends_the_park_before_the_hook_timeout','test_park_boundary_holds_under_back_to_back_closes','test_park_boundary_rechecked_just_before_the_engine_turn','test_park_test_clock_requires_the_marker','test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default','test_park_limit_lets_a_turn_outlive_the_boundary'}
    selected=[x for x in all_calls[all_calls.index(prior)+1:] if x not in clocks]
    assert len(selected)==18,selected
    # Observe public outputs before the original fixture cleanup removes them.
    observation=r'''
suite_cleanup() {
  local home capture
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    stop_home_processes "$home"
    capture="$SUPERVISION_TAIL_EVIDENCE/$(basename "$home")"
    mkdir -p "$capture"
    for file in host.out host.rc claude.err engine-report.log engine-return.log engine-ack.log state/.supervision-host.log state/.supervision-host-health state/branch-outcomes.jsonl state/.wake-queue; do
      [ ! -f "$home/$file" ] || cp "$home/$file" "$capture/$(basename "$file")"
    done
  done < <(cat "$HOMES_FILE" 2>/dev/null)
  fm_test_cleanup
}
'''
    extracted=definitions+'\n'+observation+'\n'+'\n'.join(selected)+'\n'
    selector='tests/fm-supervision-host-validation-tail.test.sh'
    (code/selector).write_text(extracted);(code/selector).chmod(0o755)
    (ev/'supervision-tail-selected.test.sh').write_text(extracted)
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','CMUX_WORKSPACE_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
    env.update(TMPDIR=str(tmp),FM_PROCEVENT_CLAIM_ROOT=str(scratch/'claims'),FM_TEST_SKIP_ORPHAN_REAP='1',SUPERVISION_TAIL_EVIDENCE=str(ev/'supervision-tail-state'))
    cmd=['bin/fm-test-run.sh','--jobs','1','--per-script-timeout-secs','1200','--json',str(ev/'supervision-tail-timing.json'),selector]
    provenance={'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'selected':selected,'command':cmd,'scratch':str(scratch),'definitions_sha256':hashlib.sha256(definitions.encode()).hexdigest(),'production_bin_equal':all((root/p.relative_to(code)).read_bytes()==p.read_bytes() for p in (code/'bin').rglob('*') if p.is_file())}
    (ev/'supervision-tail-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print('selected: '+', '.join(selected),flush=True)
    print('command: '+repr(cmd),flush=True)
    with (ev/'supervision-tail-transcript.log').open('w') as f:
        p=subprocess.Popen(cmd,cwd=code,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        for line in p.stdout:
            print(line,end='',flush=True);f.write(line);f.flush()
        rc=p.wait()
    (ev/'supervision-tail-exit.json').write_text(json.dumps({'exit':rc,'finished_epoch':time.time()},indent=2)+'\n')
    print('TAIL_EXIT='+str(rc),flush=True)
finally:
    shutil.rmtree(scratch)
    print('Disposable scratch removed: '+str(scratch),flush=True)
