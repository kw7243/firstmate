#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Codex tool sandboxes may hide the real parent process behind a bwrap pid
# namespace; in that case a CODEX_THREAD_ID-backed opaque owner is used instead.
# Foreign opaque owners fail closed because their liveness cannot be proved from
# inside the sandbox until the marker is old enough to prove it is not a
# concurrent acquisition.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

LOCK_STALE_AFTER=${FM_LOCK_STALE_AFTER:-2}
case "$LOCK_STALE_AFTER" in
  ''|*[!0-9]*) LOCK_STALE_AFTER=2 ;;
esac

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

codex_sandbox_owner() {
  local thread=${CODEX_THREAD_ID:-}
  [ -n "$thread" ] || return 1
  case "$thread" in
    *[!A-Za-z0-9._:-]*|*/*) return 1 ;;
  esac
  [ "${CODEX_SANDBOX_NETWORK_DISABLED:-}" = 1 ] || [ -n "${CODEX_SQLITE_HOME:-}" ] || return 1
  printf 'codex-thread:%s\n' "$thread"
}

current_owner() {
  local pid
  if pid=$(fm_harness_ancestry_pid); then
    printf '%s\n' "$pid"
    return 0
  fi
  codex_sandbox_owner
}

owner_is_opaque() {
  case "$1" in
    codex-thread:*) return 0 ;;
  esac
  return 1
}

opaque_owner_stale() {
  local old=$1 age
  owner_is_opaque "$old" || return 1
  age=$(fm_lock_age "$LOCK") || return 1
  [ "$age" -ge "$LOCK_STALE_AFTER" ]
}

owner_blocks_acquire() {
  local old=$1 current=${2:-}
  [ "$old" = "$current" ] && return 1
  if owner_is_opaque "$old"; then
    opaque_owner_stale "$old" && return 1
    return 0
  fi
  fm_harness_pid_alive "$old"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if owner_is_opaque "$old"; then
    if [ "$(codex_sandbox_owner 2>/dev/null || true)" = "$old" ]; then
      echo "lock: held by this sandboxed codex session"
    elif opaque_owner_stale "$old"; then
      echo "lock: stale (opaque sandbox owner older than ${LOCK_STALE_AFTER}s)"
    else
      echo "lock: held by opaque sandbox owner (liveness unavailable)"
    fi
  elif fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

me=$(current_owner) || { echo "error: cannot locate harness process in ancestry or sandbox session identity" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    if owner_is_opaque "$me"; then
      echo "lock acquired: sandbox codex session"
    else
      echo "lock acquired: harness pid $me"
    fi
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if owner_blocks_acquire "$old" "$me"; then
    echo "error: another live or unverifiable firstmate session holds the lock ($old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if owner_is_opaque "$me"; then
  echo "lock acquired: sandbox codex session"
else
  echo "lock acquired: harness pid $me"
fi
