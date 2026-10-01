#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$PWD
SCRATCH="$ROOT/.test-procevent-validation/predecessor"
mkdir -p "$SCRATCH"/{tmp,claims,lavish-state,bin,home/state}
export TMPDIR="$SCRATCH/tmp" FM_HOME="$SCRATCH/home" FM_PROCEVENT_CLAIM_ROOT="$SCRATCH/claims" LAVISH_AXI_STATE_DIR="$SCRATCH/lavish-state" PREDECESSOR_FIXTURE="$SCRATCH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
run() { printf '\n$ '; printf '%q ' "$@"; printf '\n'; "$@"; }
cleanup() {
 rc=$?
 trap - EXIT
 "$ROOT/bin/fm-procevent.sh" sweep-home || rc=1
 if compgen -G "$SCRATCH/claims/*.claim" >/dev/null; then printf 'Cleanup failed: claims remain\n'; rc=1; else printf 'Cleanup: no claims remain\n'; fi
 rm -rf "$SCRATCH"
 printf 'Cleanup: predecessor fixture removed\n'
 exit "$rc"
}
trap cleanup EXIT
cat > "$SCRATCH/bin/lavish-axi" <<'CONNECTOR'
#!/usr/bin/env bash
set -eu
case "$1" in
 --version) printf '0.1.80\n' ;;
 poll) printf 'poll started\n' >> "$PREDECESSOR_FIXTURE/polls"; while [ ! -e "$PREDECESSOR_FIXTURE/release" ]; do sleep 0.1; done; printf 'session:\n  status: ended\n' ;;
 *) exit 2 ;;
esac
CONNECTOR
chmod +x "$SCRATCH/bin/lavish-axi"
export PATH="$SCRATCH/bin:$PATH"
printf '<h1>Same-home predecessor fixture</h1>\n' > "$SCRATCH/board.html"
python3 - "$SCRATCH/board.html" "$LAVISH_AXI_STATE_DIR/state.json" <<'PY'
import hashlib,json,sys
artifact,store=sys.argv[1:];key=hashlib.sha256(artifact.encode()).hexdigest()[:16]
with open(store,'w') as f: json.dump({'sessions':{key:{'key':key,'file':artifact,'status':'open','url':'http://127.0.0.1:14387/session/'+key}}},f)
PY
printf 'Same-home control: the real listener remains alive while a new ordinary registration is armed. Lavish poll is a local blocking connector fixture; no external server is used.\n'
SID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$SCRATCH/board.html")
run "$ROOT/bin/fm-procevent-lavish.sh" arm "$SCRATCH/board.html"
for _ in $(seq 1 100); do [ -s "$SCRATCH/polls" ] && break; sleep 0.1; done
cp "$SCRATCH/claims/$SID.claim" "$SCRATCH/original.claim"
run env FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 "$ROOT/bin/fm-procevent-lavish.sh" arm "$SCRATCH/board.html" | tee "$SCRATCH/second-arm.out"
grep -q "still-listening: $SID" "$SCRATCH/second-arm.out"
cmp "$SCRATCH/original.claim" "$SCRATCH/claims/$SID.claim"
[ "$(wc -l < "$SCRATCH/polls")" -eq 1 ]
run "$ROOT/bin/fm-procevent.sh" list
run cat "$SCRATCH/polls"
printf 'Observed: same-home predecessor accepted, original real listener retained, one poll only.\n'
