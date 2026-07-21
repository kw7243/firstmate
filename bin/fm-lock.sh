#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry
# when that ancestry is visible.
# Codex tool sandboxes may hide the real parent process behind a bwrap pid
# namespace; in that case a CODEX_THREAD_ID-backed opaque owner is used instead.
# Foreign opaque owners fail closed because their liveness cannot be proved from
# inside the sandbox.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

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
  if pid=$(harness_pid); then
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

owner_blocks_acquire() {
  local old=$1 current=${2:-}
  [ "$old" = "$current" ] && return 1
  if owner_is_opaque "$old"; then
    return 0
  fi
  holder_alive "$old"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if owner_is_opaque "$old"; then
    if [ "$(codex_sandbox_owner 2>/dev/null || true)" = "$old" ]; then
      echo "lock: held by this sandboxed codex session"
    else
      echo "lock: held by opaque sandbox owner (liveness unavailable)"
    fi
  elif holder_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

me=$(current_owner) || { echo "error: cannot locate harness process in ancestry or sandbox session identity" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if owner_blocks_acquire "$old" "$me"; then
    echo "error: another live or unverifiable firstmate session holds the lock ($old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
if owner_is_opaque "$me"; then
  echo "lock acquired: sandbox codex session"
else
  echo "lock acquired: harness pid $me"
fi
