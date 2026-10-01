#!/usr/bin/env bash
set -eu
ROOT=$PWD
TMP_ROOT="$ROOT/.test-supervision/manual"
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2
mkdir -p "$TMP_ROOT/user" "$TMP_ROOT/tmp"
export HOME="$TMP_ROOT/user" TMPDIR="$TMP_ROOT/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS TASKS_AXI_FILE TASKS_AXI_BACKEND FM_AFK_MODE
export FM_HOME="$TMP_ROOT/home"
trap 'rm -rf "$TMP_ROOT"' EXIT
run() {
  local expected=$1 actual
  shift
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  set +e
  "$@"
  actual=$?
  set -e
  printf '[exit %s; expected %s]\n' "$actual" "$expected"
  [ "$actual" -eq "$expected" ]
}
run 0 bin/fm-lab-home.sh create "$FM_HOME"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '\nSCENARIO: default and explicit supervision-host opt-out\n'
run 0 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" claude
run 1 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" codex
printf 'claude\n' > "$FM_HOME/config/supervision-host"
run 0 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" codex
: > "$FM_HOME/config/supervision-host-off"
run 1 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" claude
run 1 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" codex
rm "$FM_HOME/config/supervision-host-off"
ln -s "$FM_HOME/config/missing" "$FM_HOME/config/supervision-host-off"
run 1 bash bin/fm-supervision-engine-lib.sh enabled "$FM_HOME/config" claude
rm "$FM_HOME/config/supervision-host-off" "$FM_HOME/config/supervision-host"
printf '\nSCENARIO: quiet posture becomes away; away cannot silently become quiet\n'
run 0 env FM_AFK_MODE=quiet bin/fm-afk-launch.sh enter --words 'Continue the assigned review.'
run 0 bin/fm-afk-contract.sh mode
run 0 bin/fm-afk-launch.sh enter
run 0 bin/fm-afk-contract.sh mode
run 0 env FM_AFK_MODE=quiet bin/fm-afk-contract.sh enter
run 0 bin/fm-afk-contract.sh mode
run 0 bin/fm-afk-return.sh begin
printf '\nSCENARIO: away return reports real durable outcomes and blocks on unresolved work\n'
run 0 bin/fm-afk-launch.sh enter --words 'Review the synthetic change and wait on uncertain decisions.'
run 0 bin/fm-branch-outcome.sh append --task demo --verdict routine --summary 'per your away instructions: reviewed the synthetic change'
run 0 bin/fm-branch-outcome.sh append --task demo --verdict captain --summary 'Synthetic decision still needs an answer'
printf 'window=fm-lab-synthetic:demo\nbackend=tmux\nkind=ship\n' > "$FM_HOME/state/demo.meta"
printf 'blocked [key=synthetic-token]: synthetic local token needs replacement\n' > "$FM_HOME/state/demo.status"
run 3 bin/fm-afk-return.sh begin
run 4 bin/fm-afk-return.sh guard
run 0 bin/fm-afk-return.sh catchup-summary
printf 'resolved [key=synthetic-token]: replaced the synthetic local token\n' >> "$FM_HOME/state/demo.status"
run 0 bin/fm-afk-return.sh check
run 0 bin/fm-afk-return.sh guard
printf '\nPersisted outcome store after return:\n'
cat "$FM_HOME/state/branch-outcomes.jsonl"
printf '\nSCENARIO: missing live primary CLI refuses before creating a lab\n'
run 1 bin/fm-live-lab.sh up --harness claude --source "$ROOT" --ref HEAD --timeout 1 "$TMP_ROOT/claude-lab"
run 1 bin/fm-live-lab.sh up --harness pi --source "$ROOT" --ref HEAD --timeout 1 "$TMP_ROOT/pi-lab"
[ ! -e "$TMP_ROOT/claude-lab" ] && [ ! -e "$TMP_ROOT/pi-lab" ]
printf 'Neither refused lab created a directory.\n'
cp "$FM_HOME/state/branch-outcomes.jsonl" "$EVIDENCE/supervision-outcomes.jsonl"
