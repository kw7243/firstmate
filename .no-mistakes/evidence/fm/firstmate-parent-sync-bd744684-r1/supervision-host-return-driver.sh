#!/usr/bin/env bash
set -eu
TMP_ROOT="$PWD/.test-supervision/host-report"
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2
mkdir -p "$TMP_ROOT/user" "$TMP_ROOT/tmp"
export HOME="$TMP_ROOT/user" TMPDIR="$TMP_ROOT/tmp" FM_HOME="$TMP_ROOT/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS FM_AFK_MODE TASKS_AXI_FILE TASKS_AXI_BACKEND
trap 'rm -rf "$TMP_ROOT"' EXIT
bin/fm-lab-home.sh create "$FM_HOME"
printf 'claude\n' > "$FM_HOME/config/supervision-host"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf 'Detected real harness: '
bin/fm-harness.sh
bin/fm-afk-launch.sh enter --words 'Review the isolated outcome fixture.'
bin/fm-branch-outcome.sh append --task demo --verdict routine --summary 'Synthetic routine note'
bin/fm-branch-outcome.sh append --task demo --verdict captain --summary 'Synthetic captain decision'
printf '\n$ bin/fm-afk-return.sh begin\n'
bin/fm-afk-return.sh begin > "$TMP_ROOT/return.log" 2>&1
cat "$TMP_ROOT/return.log"
grep -q 'BRANCH OUTCOMES' "$TMP_ROOT/return.log"
grep -q "the drain's BRANCH OUTCOMES section presents the visible outcomes" "$TMP_ROOT/return.log"
[ "$(grep -c 'Synthetic routine note' "$TMP_ROOT/return.log")" -eq 1 ]
[ "$(grep -c 'Synthetic captain decision' "$TMP_ROOT/return.log")" -eq 1 ]
printf '\n$ cat state/.branch-outcomes-cursor\n'
cat "$FM_HOME/state/.branch-outcomes-cursor"
[ "$(cat "$FM_HOME/state/.branch-outcomes-cursor")" = 2 ]
printf '\n$ bin/fm-wake-drain.sh\n'
bin/fm-wake-drain.sh > "$TMP_ROOT/drain.log" 2>&1
cat "$TMP_ROOT/drain.log"
! grep -q 'Synthetic routine note' "$TMP_ROOT/drain.log"
grep -q 'Synthetic captain decision' "$TMP_ROOT/drain.log"
printf '\nConfirmed: visible notes appear once at return, the routine note does not replay, and the unacknowledged captain outcome remains visible.\n'
cp "$TMP_ROOT/return.log" "$EVIDENCE/supervision-host-return.txt"
cp "$TMP_ROOT/drain.log" "$EVIDENCE/supervision-host-redrain.txt"
