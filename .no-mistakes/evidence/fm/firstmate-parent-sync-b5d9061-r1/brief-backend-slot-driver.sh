#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
SCRATCH=$ROOT/.test-brief-backend
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB
export FM_HOME=$SCRATCH/home TMPDIR=$SCRATCH/tmp
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_BACKEND TASKS_AXI_FILE TASKS_AXI_BACKEND
SLOT=$SCRATCH/treehouse-root/.treehouse/project-1237b8/1/project
PROJECT=$SCRATCH/project
export TMUX_TMPDIR
TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$FM_HOME")
worker=
cleanup() {
  if [ -n "$worker" ]; then kill "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true; fi
  tmux -L fm-lab kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME"
}
trap cleanup EXIT
# Every backend call inherits this private socket; the default server is unreachable.
tmux -L fm-lab new-session -d -s fm-lab-cleanup -c "$SCRATCH" 'sleep 600'
export TMUX=$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,0,0
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
rm -f "$FM_HOME/state/stale-task.meta" "$FM_HOME/state/live-task.meta" "$FM_HOME/state/invalid-claim.meta"
for id in stale-task live-task; do
  printf 'window=fm-lab-cleanup:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\n' "$id" "$id" "$SLOT" "$PROJECT" > "$FM_HOME/state/$id.meta"
done
. "$ROOT/bin/fm-wake-lib.sh"
fm_treehouse_slot_owner_claim "$SLOT" live-task "$FM_HOME"
printf 'claimant uncommitted work\n' > "$SLOT/claimant.txt"
( cd "$SLOT"; exec sleep 600 ) &
worker=$!
cp "$FM_HOME/state/live-task.meta" "$SCRATCH/live-task.before"
cp "${SLOT%/*}/.fm-slot-owner" "$SCRATCH/claim.before"
{
  printf '$ FM_HOME=<marked lab> bin/fm-teardown.sh stale-task\n'
  "$ROOT/bin/fm-teardown.sh" stale-task
  printf '\nPersisted-state checks after retiring stale-task:\n'
  test ! -e "$FM_HOME/state/stale-task.meta"
  printf 'stale-task.meta removed\n'
  cmp "$SCRATCH/live-task.before" "$FM_HOME/state/live-task.meta"
  printf 'live-task.meta retained byte-for-byte:\n'
  cat "$FM_HOME/state/live-task.meta"
  cmp "$SCRATCH/claim.before" "${SLOT%/*}/.fm-slot-owner"
  printf 'pool claim retained byte-for-byte:\n'
  cat "${SLOT%/*}/.fm-slot-owner"
  kill -0 "$worker"
  printf 'claimant process %s is alive\n' "$worker"
  cat "$SLOT/claimant.txt"
  git -C "$SLOT" status --short
  # An invalid claim must fail closed and preserve both task and claimant data.
  cp "$SCRATCH/live-task.before" "$FM_HOME/state/invalid-claim.meta"
  sed -i 's/live-task/invalid-claim/g' "$FM_HOME/state/invalid-claim.meta"
  printf 'not-a-claim\n' > "${SLOT%/*}/.fm-slot-owner"
  mv "$FM_HOME/state/live-task.meta" "$SCRATCH/live-task.saved"
  printf '\n$ FM_HOME=<marked lab> bin/fm-teardown.sh invalid-claim\n'
  rc=0
  "$ROOT/bin/fm-teardown.sh" invalid-claim || rc=$?
  test "$rc" -ne 0
  test -f "$FM_HOME/state/invalid-claim.meta"
  kill -0 "$worker"
  test -f "$SLOT/claimant.txt"
  printf 'Refusal exit=%s; task record, process, and claimant file retained\n' "$rc"
  mv "$SCRATCH/live-task.saved" "$FM_HOME/state/live-task.meta"
  cp "$SCRATCH/claim.before" "${SLOT%/*}/.fm-slot-owner"
} > "$EVIDENCE/brief-backend-slot-live.log" 2>&1
