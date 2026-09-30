#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; guards, startup and supervision share its
# ownership predicates. Native non-Codex sessions use verified harness ancestry
# or the trusted Claude identity. Linux Codex uses a thread identity verified
# at its native tool boundary, with namespace-qualified process metadata.
# Numeric PID equality alone never owns a Codex record. Record publication is
# owned by bin/fm-lock.sh; this library owns validation and conservative reads.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
# shellcheck source=bin/fm-process-identity-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-process-identity-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_claude_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Codex injects its thread id into each tool process. On Linux, read the
# initial environment at the nearest verified Codex boundary, not a marker
# supplied by a descendant shell. A sandbox's Codex init is itself that
# boundary; on the host it is Codex's immediate tool child. The app server may
# serve several threads and the CLI may inherit another thread's environment,
# so the long-lived host Codex environment is NOT the session identity.
# This is a harness provenance check, not a boundary against another process
# with permission to rewrite this user's home or impersonate the executable.
fm_session_lock_codex_ancestor_pid() {  # [<ancestry-pids>]
  local pid executable comm pids=${1:-}
  [ "$(uname)" = Linux ] || return 1
  if [ -z "$pids" ]; then pids=$(fm_harness_ancestry_pids) || return 1; fi
  pid=$(_fm_harness_outermost_pid "$pids") || return 1
  if ! executable=$(readlink "/proc/$pid/exe" 2>/dev/null); then
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "${comm##*/}" = codex ] || return 1
    # A known Codex ancestor with unreadable provenance must enter the
    # verification refusal, not fall back to unqualified PID ownership.
    printf '%s\n' "$pid"
    return 0
  fi
  [ "${executable##*/}" = codex ] || return 1
  printf '%s\n' "$pid"
}

fm_session_lock_trusted_codex_session_id() {  # [<ancestry-pids>]
  local anchor
  anchor=$(fm_session_lock_codex_ancestor_pid "${1:-}") || return 1
  python3 - "$$" "$anchor" <<'PYCODE'
import os, pathlib, re, sys

def initial_id(pid):
    entries = pathlib.Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    values = [entry.split(b"=", 1)[1].decode("ascii") for entry in entries
              if entry.startswith(b"CODEX_THREAD_ID=")]
    if len(values) != 1 or not re.fullmatch(
            r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", values[0]):
        raise ValueError("missing or invalid Codex thread identity")
    return values[0]

try:
    caller = os.environ.get("CODEX_THREAD_ID", "")
    pid = int(sys.argv[1])
    child = None
    for _ in range(32):
        root = pathlib.Path(f"/proc/{pid}")
        executable = pathlib.Path(os.readlink(root / "exe")).name
        fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
        parent = int(fields[1])
        if executable == "codex":
            if pid != int(sys.argv[2]):
                break
            # Namespace init is ephemeral; its inherited native environment
            # binds this call. Never confuse it with a session-lifetime PID.
            boundary = pid if pid == 1 else child
            if boundary is None:
                break
            identity = initial_id(boundary)
            if caller != identity:
                break
            print("codex:" + identity)
            sys.exit(0)
        # Do not cross another harness to pick up its launching Codex session.
        if re.fullmatch(r"claude|opencode|grok|kimi|pi|pi-signed|omp|cursor-agent", executable):
            break
        if parent < 1 or parent == pid:
            break
        child, pid = pid, parent
except (OSError, ValueError, UnicodeError, IndexError):
    pass
sys.exit(1)
PYCODE
}

fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  fm_session_lock_trusted_claude_session_id "${1:-}" && return 0
  fm_session_lock_trusted_codex_session_id "${1:-}"
}

# A Codex record has an explicit namespace and process birth. A transient
# sandbox init never proves session death, even after that tool call exits.
fm_session_lock_codex_record_present() {
  case "$(fm_session_lock_recorded_session_id "$1" 2>/dev/null)" in
    codex:*) return 0 ;;
  esac
  return 1
}

# Output globals are read only after this parser succeeds. Metadata is bound
# to the numeric lock and is exactly one record, never shell input.
fm_session_lock_read_codex_record() {  # <state> <lock-pid>
  local tag extra
  local -a codex_record_lines
  codex_record_lines=()
  while IFS= read -r tag; do codex_record_lines+=("$tag"); done < "$1/.lock-session"
  [ "${#codex_record_lines[@]}" -eq 2 ] || return 1
  [[ "${codex_record_lines[0]}" =~ ^codex:[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] || return 1
  IFS=' ' read -r tag FM_CODEX_OWNER_PID FM_CODEX_OWNER_NAMESPACE FM_CODEX_OWNER_START FM_CODEX_OWNER_KIND extra <<< "${codex_record_lines[1]}"
  [ "$tag" = codex-owner-v1 ] && [ -z "$extra" ] || return 1
  [ "$FM_CODEX_OWNER_PID" = "$2" ] || return 1
  case "$FM_CODEX_OWNER_PID:$FM_CODEX_OWNER_START" in *[!0-9:]*|:|*:|:*) return 1 ;; esac
  [ -n "$FM_CODEX_OWNER_NAMESPACE" ] || return 1
  case "$FM_CODEX_OWNER_KIND" in process|transient) ;; *) return 1 ;; esac
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same verified session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_claude_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# Codex ownership requires its validated record and the trusted thread id; an
# ended tool init does not end that thread. For the other supported harnesses:
# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Reuse this predicate's one ancestry observation for both harness paths.
  # Never cache it across calls: a parent can exit while a caller stays alive.
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_codex_record_present "$state"; then
    fm_session_lock_read_codex_record "$state" "$lock_pid" || return 1
    fm_session_lock_same_session "$state" "$pids"
    return
  fi
  # A native Codex tool must not adopt a legacy numeric record as self-owned.
  # In particular, another namespace's PID 1 is never this session's proof.
  if fm_session_lock_codex_ancestor_pid "$pids" >/dev/null; then
    return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when inspection proves a held lock that owned_by_self does not accept.
# Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller. Malformed,
# missing, stale, and unknown locks are not foreign-live-owner evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_owned_by_self "$state" && return 1
  fm_session_lock_inspect "$state"
  [ "$FM_LOCK_INSPECT_STATE" = held ] || return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: a verified same-session Codex record or a live verified harness owner.
# stale: the recorded owner ended or its PID was reused, with namespace proof
# required for a Codex process record.
# unknown: the file or pid cannot be classified without guessing, including a
# foreign transient Codex owner or a live process that is not a verified
# harness. Existence of a lock file, session record, or pane alone is never
# treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if fm_session_lock_codex_record_present "$state"; then
    fm_session_lock_read_codex_record "$state" "$pid" || return 0
    if fm_session_lock_same_session "$state"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
      return 0
    fi
    [ "$FM_CODEX_OWNER_KIND" = process ] || return 0
    [ "$(fm_process_namespace)" = "$FM_CODEX_OWNER_NAMESPACE" ] || return 0
    local current_start
    if current_start=$(fm_process_starttime "$pid"); then
      if [ "$current_start" != "$FM_CODEX_OWNER_START" ]; then
        FM_LOCK_INSPECT_STATE=stale
        FM_LOCK_INSPECT_LIVE_HARNESS=false
        return 0
      fi
    fi
  elif [ "$(fm_harness_ancestry_pid 2>/dev/null)" = 1 ]; then
    # Legacy records carry no namespace. A sandbox cannot prove them dead.
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}

# Stable ownership token for deferred work and session-derived records. Codex
# anchors can change between calls, and distinct sandbox sessions both use PID
# 1, so callers must bind to the validated session token instead of that PID.
# Native non-Codex records retain their existing numeric generation.
fm_session_lock_generation() {  # <state>
  local pid
  [ -f "$1/.lock" ] && [ ! -L "$1/.lock" ] || return 1
  pid=$(cat "$1/.lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_session_lock_codex_record_present "$1"; then
    fm_session_lock_read_codex_record "$1" "$pid" || return 1
    fm_session_lock_recorded_session_id "$1"
  else
    printf '%s\n' "$pid"
  fi
}
