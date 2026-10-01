#!/usr/bin/env bash
set -eu
ROOT=$PWD
FIX="$ROOT/.test-remote-validation/pending-live"
mkdir -p "$FIX/parent/state" "$FIX/parent/data" "$FIX/parent/config" "$FIX/mate/state" "$FIX/account"
export HOME="$FIX/account" TMPDIR="$ROOT/.test-remote-validation/tmp"
export FM_HOME="$FIX/parent" FM_ROOT_OVERRIDE="$ROOT"
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_SEND_HOOK
export FM_PENDING_REPLY_GRACE_SECS=0
printf 'mate\n' > "$FIX/mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FM_HOME" > "$FIX/mate/.fm-secondmate-parent"
touch "$FM_HOME/config/wait-no-turns"
. "$ROOT/bin/fm-pending-reply-lib.sh"
corr=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" mate 'Report the disposable release status')
fm_pending_reply_mark_delivered "$FM_HOME/state" "$corr"
fm_pending_reply_observe_busy "$FM_HOME/state" "$corr" busy
fm_pending_reply_observe_busy "$FM_HOME/state" "$corr" idle
rec=$(fm_pending_reply_path "$FM_HOME/state" "$corr")
printf 'needs-decision [key=scope]: choose narrow or wide\n' > "$FM_HOME/state/mate.status"
printf 'correlation=%s\n' "$corr"
printf 'Before recovery attempt:\n'
cat "$rec"
rc=0
fm_pending_reply_send_recovery "$FM_HOME/state" "$corr" || rc=$?
printf 'Recovery while own decision open: exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
[ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ]
[ -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]
[ ! -d "$FM_HOME/state/mate.inbox" ]
printf 'Decision still open; no recovery_attempted_epoch and no delivery inbox were created.\n'
printf 'resolved [key=scope]: narrow selected\n' >> "$FM_HOME/state/mate.status"
printf 'blocked [key=resource]: awaiting disposable artifact\n' >> "$FM_HOME/state/mate.status"
rc=0
fm_pending_reply_send_recovery "$FM_HOME/state" "$corr" || rc=$?
printf 'Recovery while own blocker open: exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
[ -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]
FM_HOME="$FIX/mate" "$ROOT/bin/fm-secondmate-report.sh" done "$corr" 'Release status ready through real parent channel'
fm_pending_reply_try_resolve "$FM_HOME/state" "$corr"
[ "$(fm_pending_reply_get "$rec" phase)" = resolved ]
printf 'Parent status after actual fm-secondmate-report:\n'
cat "$FM_HOME/state/mate.status"
printf 'Pending record after correlated reply:\n'
cat "$rec"
printf 'SCENARIO PASS: real recovery boundary suppresses own open decision and blocker, and the real report helper resolves the pending request without sending a recovery.\n'
