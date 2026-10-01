#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2
export HOME="$ROOT/.test-reply/user" TMPDIR="$ROOT/.test-reply/tmp" TMUX_TMPDIR="$ROOT/.r"
export XDG_STATE_HOME="$ROOT/.test-reply/xdg-state" FM_PROCEVENT_CLAIM_ROOT="$ROOT/.test-reply/claims"
export FM_HOME="$ROOT/.test-reply/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS TASKS_AXI_FILE TASKS_AXI_BACKEND FM_PENDING_REPLY_NOW FM_PENDING_REPLY_SEND_HOOK FM_PENDING_REPLY_DIR_OVERRIDE TMUX
export FM_PENDING_REPLY_GRACE_SECS=600 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=5
bin/fm-lab-home.sh create "$FM_HOME"
printf 'tmux\n' > "$FM_HOME/config/backend"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
. "$ROOT/bin/fm-pending-reply-lib.sh"
old=$(( $(date +%s) - 3600 ))
corr=$(FM_PENDING_REPLY_NOW="$old" fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" synthetic-mate 'Report the synthetic local review result.')
fm_pending_reply_mark_delivered "$FM_HOME/state" "$corr" "$old"
fm_pending_reply_mark_turn_completed "$FM_HOME/state" "$corr" request
record=$(fm_pending_reply_path "$FM_HOME/state" "$corr")
printf '\nSeeded record; only create/delivery describe a past timestamp; watcher uses the real clock:\n'
cat "$record"
cp "$record" "$EVIDENCE/pending-reply-live-before.txt"
[ ! -e "$FM_HOME/state/synthetic-mate.meta" ]
bin/fm-home-summary-refresh.sh
printf '\n$ bin/fm-watch-checkpoint.sh --seconds 8\n'
set +e
bin/fm-watch-checkpoint.sh --seconds 8
rc=$?
set -e
printf 'checkpoint exit=%s\n' "$rc"
[ "$rc" -eq 124 ]
phase=$(fm_pending_reply_get "$record" phase)
printf 'phase after checkpoint=%s\n' "$phase"
[ "$phase" = awaiting_report ]
[ -z "$(fm_pending_reply_get "$record" recovery_attempted_epoch)" ]
[ -z "$(fm_pending_reply_get "$record" recovery_sent_epoch)" ]
[ "$(date +%s)" -gt "$((old+600))" ]
[ "$(( $(date +%s) - $(fm_pending_reply_get "$record" request_turn_completed_epoch) ))" -lt 600 ]
[ -f "$FM_HOME/state/.last-watcher-beat" ]
cp "$record" "$EVIDENCE/pending-reply-live-awaiting.txt"
printf '\nAppend external correlated status fixture:\n'
printf 'done [corr=%s]: synthetic local review result is ready\n' "$corr" | tee "$FM_HOME/state/synthetic-mate.status"
printf '\n$ bin/fm-watch-checkpoint.sh --seconds 12\n'
set +e
bin/fm-watch-checkpoint.sh --seconds 12
rc=$?
set -e
printf 'checkpoint exit=%s\n' "$rc"
[ "$rc" -eq 0 ]
printf '\nRecord after the real watcher consumes the status:\n'
cat "$record"
[ "$(fm_pending_reply_get "$record" phase)" = resolved ]
[ "$(fm_pending_reply_get "$record" resolved_via)" = status ]
[ -z "$(fm_pending_reply_get "$record" recovery_attempted_epoch)" ]
[ -z "$(fm_pending_reply_get "$record" recovery_sent_epoch)" ]
cp "$record" "$EVIDENCE/pending-reply-live-resolved.txt"
cp "$FM_HOME/state/synthetic-mate.status" "$EVIDENCE/pending-reply-live-status.txt"
printf '\nConfirmed: old delivery did not shorten completion grace; the real watcher resolved the correlated report without recovery.\n'
