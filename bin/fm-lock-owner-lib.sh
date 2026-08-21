#!/usr/bin/env bash
# Shared validation for serialized session-lock owner tokens.
# This file is sourced by scripts and has no side effects on source.

fm_session_lock_owner_valid() {  # <owner>
  local owner=$1 thread
  case "$owner" in
    codex-thread:*)
      thread=${owner#codex-thread:}
      case "$thread" in
        ''|*[!A-Za-z0-9._:-]*) return 1 ;;
      esac
      ;;
    ''|*[!0-9]*) return 1 ;;
    *) [ "$owner" -gt 1 ] 2>/dev/null || return 1 ;;
  esac
}

fm_session_lock_owner_is_opaque() {  # <owner>
  case "$1" in
    codex-thread:*) fm_session_lock_owner_valid "$1" ;;
    *) return 1 ;;
  esac
}

fm_codex_sandbox_owner() {
  local thread=${CODEX_THREAD_ID:-} owner
  [ "${CODEX_SANDBOX_NETWORK_DISABLED:-}" = 1 ] || [ -n "${CODEX_SQLITE_HOME:-}" ] || return 1
  owner="codex-thread:$thread"
  fm_session_lock_owner_valid "$owner" || return 1
  printf '%s\n' "$owner"
}

fm_session_lock_owner_matches() {  # <state-dir> <expected-owner>
  local state=$1 expected=$2 current
  fm_session_lock_owner_valid "$expected" || return 1
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  current=$(cat "$state/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}
