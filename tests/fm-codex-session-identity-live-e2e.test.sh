#!/usr/bin/env bash
# Token-free guard run from an actual Linux Codex tool call. Repeat this exact
# command in restricted and host contexts of the same thread and compare the
# printed identity hashes. No home, lock, configuration or credential is read
# or changed. A terminal outside Codex is not equivalent to a native tool call.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CODEX_SESSION_IDENTITY_LIVE codex python3
version=$(codex --version)
[ -d /proc/self/ns ] || { printf 'skip: live: Linux-only Codex identity (%s)\n' "$version"; exit 0; }
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
identity=$(fm_session_lock_trusted_codex_session_id) \
  || fail "$version: no verified Codex tool boundary; run this guard from an actual Codex tool call"
[ "$identity" = "codex:${CODEX_THREAD_ID:-}" ] \
  || fail "$version: verified identity differs from the native tool marker"
[ "$(fm_session_lock_trusted_codex_session_id)" = "$identity" ] \
  || fail "$version: repeated identity changed inside one tool call"
if CODEX_THREAD_ID=00000000-0000-4000-8000-000000000000 fm_session_lock_trusted_codex_session_id; then
  fail "$version: caller override was accepted"
fi
printf '%s\n' "$identity" | python3 -c 'import hashlib, sys; print("identity_sha256=" + hashlib.sha256(sys.stdin.buffer.read().strip()).hexdigest())'
pass "$version: native Codex tool identity verified; repeat stable; caller override rejected"
