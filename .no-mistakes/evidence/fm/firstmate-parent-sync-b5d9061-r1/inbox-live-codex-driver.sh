#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVID=/home/ubuntu/.no-mistakes/evidence/01M3W6M4RHHDDM2YRZYDVZPYBB
LAB=$(mktemp -d "$ROOT/.test-inbox-validation/fm-lab.XXXXXX")
SOCKDIR=
cleanup() {
  if [ -n "$SOCKDIR" ]; then TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab kill-server 2>/dev/null || true; fi
  bin/fm-lab-home.sh teardown "$LAB" || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
printf 'tmux\n' > "$LAB/config/backend"
printf 'manual\n' > "$LAB/config/backlog-backend"
touch "$LAB/config/wait-no-turns"
mkdir -p "$LAB/state/live-codex.inbox/handled"
export TMUX_TMPDIR="$SOCKDIR"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
 tmux -L fm-lab new-session -d -s primary -n fm-live-codex -x 220 -y 50 -c "$ROOT" \
 -e FM_HOME="$LAB" -e FM_TASK_ID=live-codex -e FM_TASK_INBOX="$LAB/state/live-codex.inbox" \
 codex --dangerously-bypass-approvals-and-sandbox --disable hooks
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
printf 'window=primary:fm-live-codex\nkind=ship\nharness=codex\nbackend=tmux\n' > "$LAB/state/live-codex.meta"
sleep 5
tmux -L fm-lab send-keys -t primary Escape
sleep 3
tmux -L fm-lab capture-pane -p -t primary > "$EVID/inbox-codex-startup.txt"
cat "$EVID/inbox-codex-startup.txt"
if grep -Eiq 'Update now|trust the contents|sign in' "$EVID/inbox-codex-startup.txt"; then
  printf 'STARTUP_BLOCKED=modal_not_dismissed\n'
  exit 2
fi
# Save the lab reference only within the disposable scratch for inspection.
printf '%s\n%s\n' "$LAB" "$SOCKDIR" > "$ROOT/.test-inbox-validation/live-lab-reference"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" \
 "$ROOT/bin/fm-send.sh" live-codex "Isolated validation: your only task is to write the exact text inbox-live-verified to $LAB/acted.txt, then acknowledge this instruction by moving its .msg file into handled/. Do not start a supervisor, contact services, or perform other repository work. Reply briefly when done."
for ((n=0;n<90;n++)); do
  if [ -f "$LAB/acted.txt" ] && [ -f "$LAB/state/live-codex.inbox/handled/001.msg" ]; then break; fi
  sleep 1
done
tmux -L fm-lab capture-pane -p -S -200 -t primary > "$EVID/inbox-codex-final.txt"
cat "$EVID/inbox-codex-final.txt"
if [ -f "$LAB/acted.txt" ] && [ -f "$LAB/state/live-codex.inbox/handled/001.msg" ]; then
  cat "$LAB/acted.txt"
  cp "$LAB/state/live-codex.inbox/handled/001.msg" "$EVID/inbox-codex-handled.msg"
  printf '\nLIVE_DELIVERY=acted_and_acknowledged\n'
else
  printf '\nLIVE_DELIVERY=not_completed\n'
  exit 1
fi
