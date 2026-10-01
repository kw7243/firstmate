#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-default-off/fm-lab.XXXXXX")
SOCKDIR=
WPID=
cleanup() {
  if [ -n "$WPID" ]; then kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fi
  if [ -n "$SOCKDIR" ]; then TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab kill-server 2>/dev/null || true; fi
  bin/fm-lab-home.sh teardown "$LAB" || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
export TMUX_TMPDIR="$SOCKDIR" FM_HOME="$LAB"
printf 'tmux\n' > "$LAB/config/backend"
printf 'manual\n' > "$LAB/config/backlog-backend"
mkdir -p "$LAB/state/default-off.inbox/handled"
tmux -L fm-lab new-session -d -s primary -n fm-default-off -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" -e FM_TASK_ID=default-off -e FM_TASK_INBOX="$LAB/state/default-off.inbox" codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c check_for_update_on_startup=false
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
sleep 8
capture=$(tmux -L fm-lab capture-pane -p -t primary)
if printf '%s' "$capture" | grep -Eiq 'Update now|Do you trust'; then echo 'unexpected modal'; exit 1; fi
printf 'window=primary:fm-default-off\nkind=secondmate\nharness=codex\nbackend=tmux\nhome=%s\n' "$LAB" > "$LAB/state/default-off.meta"
tmux -L fm-lab send-keys -t primary -l 'Unsubmitted default-off validation draft'
bin/fm-send.sh default-off --fire-and-forget 0000000000000011 'Disposable test: reply briefly and acknowledge this message if read.'
[ -f "$LAB/state/default-off.inbox/001.msg" ]
[ ! -e "$LAB/state/default-off.inbox/.retry-ring" ]
printf 'ABSENT FLAG: 001.msg durable; no retry marker\n'
touch "$LAB/config/wait-no-turns"
bin/fm-send.sh default-off --fire-and-forget 0000000000000012 'Disposable second test: reply briefly and acknowledge this message if read.'
[ "$(cat "$LAB/state/default-off.inbox/.retry-ring")" = 002.msg ]
printf 'PRESENT FLAG: 002.msg durable; retry marker=%s\n' "$(cat "$LAB/state/default-off.inbox/.retry-ring")"
rm "$LAB/config/wait-no-turns"
FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_TASK_INBOX_GRACE_SECS=1 bin/fm-watch.sh > "$LAB/watcher.log" 2>&1 &
WPID=$!
sleep 15
kill -0 "$WPID"
[ "$(cat "$LAB/state/default-off.inbox/.retry-ring")" = 002.msg ]
[ ! -e "$LAB/state/default-off.inbox/.ring-state" ]
printf 'REMOVED FLAG: live watcher keeps 002.msg retry dormant; no ordinary retry ladder\n'
cat "$LAB/watcher.log"
tmux -L fm-lab capture-pane -p -t primary
