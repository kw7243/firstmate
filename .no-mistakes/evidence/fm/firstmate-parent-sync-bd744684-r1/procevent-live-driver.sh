#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$PWD
SCRATCH="$ROOT/.test-procevent-validation/manual"
EVIDENCE=/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2
mkdir -p "$SCRATCH"/{tmp,claims,lavish-state,bin,home-a/state,home-b/state,when-home/state,alternate-state}
export TMPDIR="$SCRATCH/tmp" FM_PROCEVENT_CLAIM_ROOT="$SCRATCH/claims" LAVISH_AXI_STATE_DIR="$SCRATCH/lavish-state"
export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=5 FM_SEND_SETTLE=0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_GATE_REFUSE_BYPASS
run() { printf '\n$ '; printf '%q ' "$@"; printf '\n'; "$@"; }
pe() { local h=$1; shift; run env FM_HOME="$h" "$ROOT/bin/fm-procevent.sh" "$@"; }
lav() { local h=$1; shift; run env FM_HOME="$h" "$ROOT/bin/fm-procevent-lavish.sh" "$@"; }
await_file() { for _ in $(seq 1 200); do [ -s "$1" ] && return 0; sleep 0.1; done; printf 'Timed out: %s\n' "$1"; return 1; }
await_absent() { for _ in $(seq 1 200); do [ ! -e "$1" ] && return 0; sleep 0.1; done; printf 'Still present: %s\n' "$1"; return 1; }
cleanup() {
  local rc=$? h f id seq
  trap - EXIT
  for h in "$SCRATCH/when-home" "$SCRATCH/home-a" "$SCRATCH/home-b"; do
    for f in "$h/state/procevent-inbox/"*.result; do
      [ -f "$f" ] || continue
      id=${f##*/}; id=${id%.result}; seq=${id##*.}; id=${id%.*}
      FM_HOME="$h" "$ROOT/bin/fm-procevent.sh" handled "$id" "$seq" >/dev/null 2>&1 || true
    done
    FM_HOME="$h" "$ROOT/bin/fm-procevent.sh" sweep-home || rc=1
  done
  FM_HOME="$SCRATCH/home-a" FM_STATE_OVERRIDE="$SCRATCH/alternate-state" "$ROOT/bin/fm-procevent.sh" sweep-home || rc=1
  if compgen -G "$SCRATCH/claims/*.claim" >/dev/null; then printf 'Cleanup failed: claims remain\n'; rc=1; else printf 'Cleanup: no process-event claims remain\n'; fi
  rm -rf -- "$SCRATCH"
  printf 'Cleanup: removed disposable manual homes and connector fixtures\n'
  exit "$rc"
}
trap cleanup EXIT
printf 'Scenario 1: Real condition/action source registers, captures output, wakes, and acknowledges once.\n'
run env FM_HOME="$SCRATCH/when-home" "$ROOT/bin/fm-procevent-when.sh" arm evidence --interval 0.1 --stable 1 --deadline 60 --condition test -f "$SCRATCH/condition-ready" --action printf 'local action completed\n'
pe "$SCRATCH/when-home" reconcile
pe "$SCRATCH/when-home" list
run touch "$SCRATCH/condition-ready"
RESULT="$SCRATCH/when-home/state/procevent-inbox/when-evidence.1.result"
await_file "$RESULT"
await_file "$SCRATCH/when-home/state/.wake-queue"
run cat "$RESULT"
run cat "$SCRATCH/when-home/state/.wake-queue"
run env FM_HOME="$SCRATCH/when-home" "$ROOT/bin/fm-procevent.sh" classify "$RESULT"
pe "$SCRATCH/when-home" handled when-evidence 1
pe "$SCRATCH/when-home" handled when-evidence 1
run env FM_HOME="$SCRATCH/when-home" "$ROOT/bin/fm-procevent-when.sh" retire evidence
pe "$SCRATCH/when-home" list
printf '\nScenario 2: Real registration/delivery path with a recording Lavish connector; no external server or post.\n'
export EVIDENCE_CONNECTOR_ROOT="$SCRATCH"
cat > "$SCRATCH/bin/lavish-axi" <<'CONNECTOR'
#!/usr/bin/env bash
set -eu
case "$1" in
  --version) printf '0.1.80\n' ;;
  reply)
    printf 'reply: ' >> "$EVIDENCE_CONNECTOR_ROOT/replies"
    cat "$4" >> "$EVIDENCE_CONNECTOR_ROOT/replies"
    printf 'reply accepted locally\n' ;;
  poll)
    round=1
    [ ! -e "$EVIDENCE_CONNECTOR_ROOT/poll-one-started" ] || round=2
    printf 'poll round %s started\n' "$round" > "$EVIDENCE_CONNECTOR_ROOT/poll-$round-started"
    touch "$EVIDENCE_CONNECTOR_ROOT/poll-one-started"
    while [ ! -e "$EVIDENCE_CONNECTOR_ROOT/release-$round" ]; do sleep 0.1; done
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","Please confirm the change","","message",""\n' ;;
  *) exit 2 ;;
esac
CONNECTOR
cat > "$SCRATCH/bin/tmux" <<'CONNECTOR'
#!/usr/bin/env bash
printf 'isolated notification connector: %s\n' "$*" >> "$EVIDENCE_CONNECTOR_ROOT/notifications"
case "$1" in
  display-message) printf 'private-fixture-pane\n' ;;
  capture-pane) printf 'fixture prompt>\n' ;;
esac
exit 0
CONNECTOR
chmod +x "$SCRATCH/bin/"*
export PATH="$SCRATCH/bin:$PATH"
printf '<h1>Disposable reply-ownership board</h1>\n' > "$SCRATCH/board.html"
python3 - "$SCRATCH/board.html" "$LAVISH_AXI_STATE_DIR/state.json" <<'PY'
import hashlib,json,sys
artifact,store=sys.argv[1:]
key=hashlib.sha256(artifact.encode()).hexdigest()[:16]
with open(store,'w') as f: json.dump({'sessions':{key:{'key':key,'file':artifact,'status':'open','url':'http://127.0.0.1:14387/session/'+key}}},f)
PY
for pair in 'home-a owner' 'home-b intruder'; do
  read -r h task <<< "$pair"
  printf 'window=disposable:fm-%s\nworktree=%s/worktree-%s\nproject=disposable\n' "$task" "$SCRATCH" "$task" > "$SCRATCH/$h/state/$task.meta"
done
cp "$SCRATCH/home-b/state/intruder.meta" "$SCRATCH/alternate-state/intruder.meta"
printf 'accepted home A reply\n' > "$SCRATCH/owner-reply"
printf 'must never be sent by home B\n' > "$SCRATCH/foreign-reply"
SID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$SCRATCH/board.html")
lav "$SCRATCH/home-a" arm "$SCRATCH/board.html" --for owner --agent-reply-file "$SCRATCH/owner-reply"
await_file "$SCRATCH/poll-1-started"
pe "$SCRATCH/home-a" list
run cat "$SCRATCH/replies"
cp "$SCRATCH/replies" "$SCRATCH/expected-replies"
cp "$SCRATCH/claims/$SID.claim" "$SCRATCH/expected-claim"
printf '\nAdversarial: home B attempts a reply while home A owns the live claim.\n'
rc=0
lav "$SCRATCH/home-b" arm "$SCRATCH/board.html" --for intruder --agent-reply-file "$SCRATCH/foreign-reply" || rc=$?
printf 'foreign-home exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
cmp "$SCRATCH/replies" "$SCRATCH/expected-replies"
cmp "$SCRATCH/claims/$SID.claim" "$SCRATCH/expected-claim"
[ ! -e "$SCRATCH/home-b/state/procevent/$SID.source" ]
printf 'Observed: no additional send, no foreign task registration, original live claim unchanged.\n'
printf '\nAdversarial: same home string with a different state root attempts a reply.\n'
rc=0
run env FM_HOME="$SCRATCH/home-a" FM_STATE_OVERRIDE="$SCRATCH/alternate-state" "$ROOT/bin/fm-procevent-lavish.sh" arm "$SCRATCH/board.html" --for intruder --agent-reply-file "$SCRATCH/foreign-reply" || rc=$?
printf 'foreign-state exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
cmp "$SCRATCH/replies" "$SCRATCH/expected-replies"
cmp "$SCRATCH/claims/$SID.claim" "$SCRATCH/expected-claim"
printf '\nAdversarial: home B ordinary arm must not adopt home A as a predecessor.\n'
rc=0
lav "$SCRATCH/home-b" arm "$SCRATCH/board.html" || rc=$?
printf 'foreign predecessor exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
cmp "$SCRATCH/claims/$SID.claim" "$SCRATCH/expected-claim"
printf '\nControl: same home completes a feedback round and re-arms with its next reply.\n'
run touch "$SCRATCH/release-1"
await_file "$SCRATCH/home-a/state/procevent-inbox/$SID.1.result"
await_absent "$SCRATCH/claims/$SID.claim"
run env FM_HOME="$SCRATCH/home-a" "$ROOT/bin/fm-procevent-lavish.sh" read "$SCRATCH/home-a/state/procevent-inbox/$SID.1.result"
printf 'accepted same-home second reply\n' > "$SCRATCH/owner-reply-2"
lav "$SCRATCH/home-a" arm "$SCRATCH/board.html" --for owner --agent-reply-file "$SCRATCH/owner-reply-2"
await_file "$SCRATCH/poll-2-started"
run cat "$SCRATCH/replies"
run cat "$SCRATCH/home-a/state/procevent-inbox/$SID.1.handled"
[ "$(wc -l < "$SCRATCH/replies")" -eq 2 ]
pe "$SCRATCH/home-a" list
printf 'Observed: both same-home replies accepted once; foreign reply never sent; completed round acknowledged and next listener live.\n'
