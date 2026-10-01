#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
printf '# Mentioned but never offered\n' > "$REMOTE/data/reply/prose-only.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
if [ -n "${FM_REMOTE_REPLY_POLL_LOG:-}" ]; then
  printf 'x\n' >> "$FM_REMOTE_REPLY_POLL_LOG"
fi
[ "${FM_REMOTE_REPLY_FAIL_READ:-}" != 1 ] || exit 255
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS="${FM_REMOTE_REPLY_WAIT_SECONDS:-10}" \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}

stop_reply_listener() {
  local pid _
  pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# Block until this generation's capture has been applied. A live listener keeps
# its claim across polls, so start is only launched when nothing owns the source.
await_reply_result() { # <result-path>
  local result=$1 handled=${1%.result}.handled _
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 800); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
printf 'Real Firstmate remote job worker and reply relay, with isolated local SSH transport fixture.\n'
remote_env "$ADAPTER" arm ios
: > "$TMP_ROOT/preempted-polls"
FM_REMOTE_REPLY_POLL_LOG="$TMP_ROOT/preempted-polls" FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/live-start.out" 2>&1 &
PREEMPTED_RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "the listener never claimed its source"
HELD_PID=$(sed -n '2p' "$CLAIMS/$SID.claim")
running_poll=''
for _ in $(seq 1 200); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.1
done
[ -n "$running_poll" ] || fail "reply poll never began"
printf '\nBefore interruption: listener pid=%s\n' "$HELD_PID"
remote_env "$ROOT/bin/fm-procevent.sh" list
printf '\nRun non-poll remote job against the same home to preempt its waiting read:\n'
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144
for _ in $(seq 1 200); do
  polls=$(wc -l < "$TMP_ROOT/preempted-polls" | tr -d ' ')
  [ "$polls" -ge 2 ] && break
  sleep 0.1
done
[ "$polls" -ge 2 ] || fail "preempted listener did not poll again"
[ "$(reply_owner)" = live ] || fail "preemption released source ownership"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] || fail "preemption replaced listener"
[ ! -e "$PARENT/state/remote-replies/ios.caught-up" ] || fail "preemption fabricated channel freshness"
printf '\nAfter interruption: same listener pid=%s polls=%s; no caught-up watermark\n' "$HELD_PID" "$polls"
remote_env "$ROOT/bin/fm-procevent.sh" list
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
printf '%s\n' "$reconcile_out"
assert_contains "$reconcile_out" 'started=0' "reconcile relaunched an already-owned listener"
printf 'working [corr=abcdefabcdefabcd]: reply after preemption\n' >> "$REMOTE/state/parent-replies.status"
for _ in $(seq 1 400); do
  [ -f "$PARENT/state/ios.status" ] && grep -q 'reply after preemption' "$PARENT/state/ios.status" && break
  sleep 0.1
done
grep -q 'reply after preemption' "$PARENT/state/ios.status" || fail "reply after preemption was not mirrored"
printf '\nMirrored status after preemption:\n'
cat "$PARENT/state/ios.status"
printf '\nDurable result:\n'
cat "$PARENT/state/procevent-inbox/$SID.1.result"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] || fail "delta replaced listener"
stop_reply_listener || fail "listener did not stop"
wait "$PREEMPTED_RUNNER" 2>/dev/null || true
remote_env "$ROOT/bin/fm-procevent.sh" sweep-home
printf 'Cleanup: scoped source swept; EXIT trap stops private worker tree and removes fixture home.\n'
