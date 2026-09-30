#!/usr/bin/env bash
set -eu
. ./bin/fm-session-lock-lib.sh
identity=$(fm_session_lock_trusted_codex_session_id)
[ "$identity" = "codex:$CODEX_THREAD_ID" ]
[ "$(fm_session_lock_trusted_codex_session_id)" = "$identity" ]
if CODEX_THREAD_ID=00000000-0000-4000-8000-000000000000 fm_session_lock_trusted_codex_session_id; then
  echo 'ERROR: forged caller accepted'; exit 1
fi
printf 'pid1='
ps -p 1 -o comm=
printf 'namespace='
readlink /proc/self/ns/pid
printf '%s' "$identity" | python3 -c 'import hashlib,sys;print("identity_sha256="+hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
state="$PWD/.no-mistakes/test-phase/native-home/state"
fm_session_lock_owned_by_self "$state"
[ "$(fm_session_lock_generation "$state")" = "$identity" ]
printf 'Existing host-created session lock is self-owned; stable generation matches; caller override rejected.\n'
