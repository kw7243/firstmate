#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-supervision-validation/lab"
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
  for scenario in park checkpoint close; do
    FM_HOME="$LAB/$scenario" bin/fm-watch-arm.sh --stop >/dev/null 2>&1 || true
  done
  bin/fm-lab-home.sh teardown "$LAB"
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM
for scenario in park checkpoint close; do
  bin/fm-lab-home.sh create "$LAB/$scenario"
  : > "$LAB/$scenario/config/supervision-host"
done
printf '%s\n' "$SOCKET_DIR" > "$ROOT/.test-supervision-validation/socket-dir"
cat > "$LAB/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -eu
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB
exec > "$EVIDENCE/supervision-live-product.txt" 2>&1
unset FM_TEST_SEAM FM_TEST_SUPERVISION_HOST_CLOCK FM_GATE_REFUSE_BYPASS
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SUPERVISION_HOST_PRIMARY=codex
LAB_ROOT=$FM_HOME
export FM_HOME="$LAB_ROOT/park"
printf 'REAL PRIMARY LOCK\n'
bin/fm-lock.sh || exit 1
bin/fm-lock.sh status
printf '\nBOUNDARY SCENARIO: real host with 6-second park\n'
start=$SECONDS
FM_SUPERVISION_HOST_PARK_SECONDS=6 bin/fm-supervision-host.sh park
rc=$?
printf 'boundary_rc=%s elapsed_seconds=%s\n' "$rc" "$((SECONDS-start))"
[ "$rc" -eq 0 ] || exit "$rc"
export FM_HOME="$LAB_ROOT/checkpoint"
bin/fm-lock.sh
printf '\nCHECKPOINT SCENARIO: quiet 6-second checkpoint\n'
set +e
start=$SECONDS
bin/fm-watch-checkpoint.sh --seconds 6
rc=$?
printf 'checkpoint_rc=%s elapsed_seconds=%s\n' "$rc" "$((SECONDS-start))"
[ "$rc" -eq 124 ] || exit 1
set -e
export FM_HOME="$LAB_ROOT/close"
bin/fm-lock.sh
printf '\nCLOSE SCENARIO: wait for real watcher then append task status\n'
: > "$FM_HOME/state/demo.status"
printf 'project=lab\nwindow=primary:demo\nharness=codex\nbackend=tmux\n' > "$FM_HOME/state/demo.meta"
(
  for i in $(seq 1 120); do
    if [ -f "$FM_HOME/state/.watch.lock/pid" ]; then
      sleep 2
      printf 'done: supervised lab close evidence\n' >> "$FM_HOME/state/demo.status"
      exit 0
    fi
    sleep 0.25
  done
  exit 1
) &
writer=$!
start=$SECONDS
FM_SUPERVISION_HOST_PARK_SECONDS=20 bin/fm-supervision-host.sh park
rc=$?
wait "$writer"
printf 'close_rc=%s elapsed_seconds=%s\n' "$rc" "$((SECONDS-start))"
printf '\nHOST LEDGER\n'
for scenario in park checkpoint close; do
  printf '%s\n' "$scenario"
  cat "$LAB_ROOT/$scenario/state/.supervision-host.log"
done
printf '\nDURABLE WAKE QUEUE\n'
cat "$FM_HOME/state/.wake-queue"
: > "$LAB_ROOT/finished"
DRIVE
chmod +x "$LAB/drive.sh"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -x 140 -y 45 -s primary -c "$ROOT" -e FM_HOME="$LAB" 'codex --disable hooks --sandbox danger-full-access --ask-for-approval never -c check_for_update_on_startup=false'
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-window -d -t primary -n demo -c "$ROOT" 'sleep 600'
for i in $(seq 1 900); do
  [ ! -e "$LAB/finished" ] || break
  sleep 1
done
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t primary:0 -S -300 > "$EVIDENCE/supervision-live-pane.txt"
