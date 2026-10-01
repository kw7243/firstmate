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
await_reply_result() { # <result-path> [tries]
  local result=$1 handled=${1%.result}.handled _ tries=${2:-800}
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 "$tries"); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  if [ ! -s "$result" ]; then
    printf 'timed out waiting for capture: %s\n' "$result" >&2
  else
    printf 'timed out waiting for application: %s\n' "$result" >&2
  fi
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
export REPLAY_HOME="$PARENT" REPLAY_REMOTE="$REMOTE"
python3 - <<'RESTORE'
import os,re,hashlib
from pathlib import Path
s=Path('/home/ubuntu/.no-mistakes/evidence/01M3T84JP9X8B71Q5FT96AR7D2/remote-reply-retry-state.log').read_text()
# The evidence dump frames these generated protocol records with their relative paths.
def block(name):
 start=s.index('\n'+name+'\n')+len(name)+2
 m=re.search(r'\n(?:await-[^\n]+\.out|claims/[^\n]+|parent/state/[^\n]+|remote-jobs/[^\n]+)\n',s[start:])
 return s[start:start+m.start()] if m else s[start:]
home=Path(os.environ['REPLAY_HOME']);remote=Path(os.environ['REPLAY_REMOTE'])
inbox=home/'state/procevent-inbox';inbox.mkdir()
result=block('parent/state/procevent-inbox/remote-reply-ios.22.result')
# One separator newline belongs to the dump, not to the captured protocol.
if result.endswith('\n\n'): result=result[:-1]
header,payload=result.split('\n\n',1)
fields=dict(line.split('=',1) for line in header.splitlines())
assert len(payload.encode())==int(fields['payload_bytes']), (len(payload.encode()),fields['payload_bytes'])
assert hashlib.sha256(payload.encode()).hexdigest()==fields['payload_sha256']
(inbox/'remote-reply-ios.22.result').write_text(result)
(inbox/'remote-reply-ios.22.adapter').write_text('remote-reply\n')
status=block('parent/state/ios.status')
if status.endswith('\n\n'): status=status[:-1]
(home/'state/ios.status').write_text(status)
# Rebuild the persisted source-identity ledger from the previously mirrored
# whole source payload using its documented C0/DEL normalization contract.
normal=''.join('?' if (ord(c)<32 and c not in '\t\n') or ord(c)==127 else c for c in payload)
(home/'state/.remote-reply-mirrored-ios').write_text(normal)
(remote/'state/parent-replies.status').write_text(payload)
for name in sorted(set(re.findall(r'data/[A-Za-z0-9_./-]+\.md',payload))):
 if name in ['data/reply/never-written.md','data/remote-secondmates/other/data/reply/report.md']: continue
 p=remote/name;p.parent.mkdir(parents=True,exist_ok=True)
 p.write_text('# Isolated replay document\n'+name+'\n')
(remote/'data/reply/big.md').write_text('x'*300000)
(remote/'data/reply/replay.md').write_text('# replay decision report\n')
print('Restored exact captured payload:',len(payload.encode()),'bytes; SHA-256 verified.')
print('Restored prior parent status; source ledger reconstructed from already-mirrored normalized source lines.')
RESTORE
RESULT="$PARENT/state/procevent-inbox/$SID.22.result"
cp "$PARENT/state/ios.status" "$TMP_ROOT/status-before-replay"
printf '\nDrive the repaired whole-log await through the real running process-event source.\n'
began=$(date +%s)
remote_env "$ADAPTER" arm ios
rm "$RESULT" "${RESULT%.result}.adapter"
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
await_reply_result "$RESULT" 2400 || fail "saved whole-log result did not finish capture and application"
printf 'await completed duration_seconds=%s\n' "$(( $(date +%s) - began ))"
cmp "$TMP_ROOT/status-before-replay" "$PARENT/state/ios.status" || fail "replay changed already-mirrored parent status"
printf 'Observed: parent status bytes unchanged; replay decision was not duplicated or reopened.\n'
cmp "$REMOTE/data/reply/replay.md" "$PARENT/data/remote-secondmates/ios/data/reply/replay.md" || fail "replay did not deliver current document bytes"
[ -f "$PARENT/state/procevent-inbox/$SID.1.handled" ] || fail "replay was not durably acknowledged"
printf 'Delivered replay document:\n'
cat "$PARENT/data/remote-secondmates/ios/data/reply/replay.md"
printf 'Committed cursor:\n'
cat "$PARENT/state/remote-replies/ios.cursor"
remote_env "$ROOT/bin/fm-procevent.sh" sweep-home
