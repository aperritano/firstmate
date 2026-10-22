import os, pathlib, subprocess, time, signal, shutil
root=pathlib.Path.cwd(); scratch=root/'.rex-validation'; shim=scratch/'slow-bin'; shim.mkdir(exist_ok=True)
real=shutil.which('rex'); assert real
(shim/'rex').write_text('''#!/usr/bin/env bash
case " $* " in
  *" server run "*) printf '%s\\n' "$$" > "$PROBE_DIR/server-pid" ;;
  *" server.status "*) touch "$PROBE_DIR/polling"; sleep 3 ;;
esac
exec "$PROBE_REAL" "$@"
''')
(shim/'rex').chmod(0o755)
env=os.environ.copy()
for key in ['TMPDIR','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(key,None)
env.update(REX_BIN_DIR=str(shim),PROBE_DIR=str(scratch),PROBE_REAL=real)
p=subprocess.Popen(['bash','tests/fm-backend-rex-smoke.test.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try:
    for _ in range(150):
        if (scratch/'polling').exists() and (scratch/'server-pid').exists(): break
        if p.poll() is not None: raise RuntimeError(p.communicate()[0].decode())
        time.sleep(.05)
    else: raise RuntimeError('no readiness poll')
    server=int((scratch/'server-pid').read_text())
    # Read only this owned process's argv to record the scratch path before cleanup.
    argv=subprocess.check_output(['ps','-p',str(server),'-o','command='],text=True).strip()
    print('Real server during readiness:',argv,flush=True)
    p.send_signal(signal.SIGTERM)
    output,_=p.communicate(timeout=20)
    print('Interrupted suite exit:',p.returncode)
    print(output.decode(),end='')
    try: os.kill(server,0)
    except ProcessLookupError: print('PASS: readiness interruption terminated owned real server')
    else: raise RuntimeError('server leaked')
    state=argv.split('--state-dir ',1)[1].split(' ',1)[0]
    work=pathlib.Path(state).parent
    assert not work.exists(), f'leaked state: {work}'
    print('PASS: readiness interruption removed owned scratch directory')
finally:
    if p.poll() is None:
        p.terminate(); p.wait(timeout=20)
