import os, pathlib, re, shutil, subprocess
root=pathlib.Path.cwd()
home=root/'.test-brief-backend/home'
evidence=pathlib.Path('/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB')
env={k:v for k,v in os.environ.items() if not(k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','FM_BACKEND','FM_HOME']))}
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-brief-backend/tmp'))
log=[]
for flag in [False,True]:
    if flag: (home/'config/wait-no-turns').touch()
    for verb in (['paused'] if not flag else ['paused','awaiting']):
        for kind in ['ship','scout']:
            ident=f'brief-live-{kind}-'+('off' if not flag else verb)
            cmd=['bin/fm-brief.sh',ident,'fixture-project']+(['--mode','no-mistakes'] if kind=='ship' else ['--scout'])
            caseenv=env|{'FM_CLASSIFY_PAUSED_VERB':verb}
            proc=subprocess.run(cmd,env=caseenv,text=True,capture_output=True)
            log.append('$ FM_HOME=<disposable lab> FM_CLASSIFY_PAUSED_VERB='+verb+' '+' '.join(cmd)+'\n'+proc.stdout+proc.stderr)
            assert proc.returncode==0,(cmd,proc.returncode)
            brief=(home/'data'/ident/'brief.md').read_text()
            blocks=re.findall(r'^# Waiting\n(.*?)(?=^# |\Z)',brief,flags=re.S|re.M)
            assert bool(blocks)==flag
            if flag:
                declarations=re.findall(r'`(\w+):`',blocks[0])[-2:]
                assert declarations==[verb,verb],declarations
                for declaration in declarations:
                    check=subprocess.run(['bash','-c','. bin/fm-classify-lib.sh; status_is_paused "$1 waiting for validation"','_',declaration+':'],env=caseenv,text=True,capture_output=True)
                    log.append('Classifier consumes emitted '+declaration+': waiting for validation -> exit '+str(check.returncode))
                    assert check.returncode==0
                assert 'Do not poll or list the inbox while waiting' in brief
                if kind=='ship': assert 'issue the same foreground call again' in brief and 'background the drive call' not in brief
            else:
                assert 'Do not poll or list the inbox while waiting' not in brief
                if kind=='ship': assert 'background the drive call' in brief
            shutil.copyfile(home/'data'/ident/'brief.md',evidence/f'brief-backend-{ident}.md')
            log.append('Generated contract result: waiting section='+str(flag)+', kind='+kind+', configured declaration='+verb)
(evidence/'brief-backend-contract-transcript.log').write_text('\n\n'.join(log)+'\n')
print('\n'.join(log))
