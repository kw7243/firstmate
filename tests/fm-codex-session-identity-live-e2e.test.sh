#!/usr/bin/env bash
# Token-free guard run from an actual Linux Codex tool call. Repeat this exact
# command in restricted and host contexts of the same thread and compare the
# printed identity hashes. Startup checks use only a disposable home with fake
# sweep producers; no live home, configuration or credential is changed.
# A terminal outside Codex is not equivalent to a native tool call.
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

# Exercise the actual tool lifetime with fake sweep producers in a disposable
# home. A transient call must settle its worker before returning; a persistent
# host keeps the existing deferred path. Neither path touches the live fleet.
TMP_ROOT=$(fm_test_tmproot fm-codex-startup-live)
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/root/bin" "$TMP_ROOT/home/state"
for script in "$ROOT"/bin/*.sh; do
  case "${script##*/}" in fm-bootstrap.sh|fm-inactive-reconcile.sh|fm-herdr-session-cleanup.sh) continue ;; esac
  ln -s "$script" "$TMP_ROOT/root/bin/${script##*/}"
done
ln -s "$ROOT/docs" "$TMP_ROOT/root/docs"
cat > "$TMP_ROOT/root/bin/fm-bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${FM_BOOTSTRAP_NETWORK:-}" = only ] || exit 0
# The original detached worker cannot finish before its caller returns: let
# the local digest finish, then keep work pending for two more seconds.
for ((i=0; i<300; i++)); do
  if grep -q 'NEXT STEP' "$FM_HOME/startup.out" 2>/dev/null; then break; fi
  sleep 0.1
done
grep -q 'NEXT STEP' "$FM_HOME/startup.out"
sleep 2
printf 'BOOTSTRAP_INFO: live fixture completed\n'
STUB
for script in fm-inactive-reconcile.sh fm-herdr-session-cleanup.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/root/bin/$script"
done
chmod +x "$TMP_ROOT/root/bin/fm-bootstrap.sh" "$TMP_ROOT/root/bin/fm-inactive-reconcile.sh" "$TMP_ROOT/root/bin/fm-herdr-session-cleanup.sh"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/root"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_SESSION_START_STAGE_FILE
bash "$FM_ROOT_OVERRIDE/bin/fm-session-start.sh" > "$FM_HOME/startup.out" 2>&1
if fm_session_lock_transient_codex; then
  grep -q 'FOREGROUND NETWORK CHECKS' "$FM_HOME/startup.out" \
    || fail "$version: transient startup omitted foreground checks: $(cat "$FM_HOME/startup.out")"
  printf 'startup_context=transient\n'
else
  bash "$FM_ROOT_OVERRIDE/bin/fm-startup-network.sh" wait 30 \
    || fail "$version: persistent worker did not finish"
  printf 'startup_context=persistent\n'
fi
grep -qx state=done "$FM_HOME/state/.startup-network.status" \
  || fail "$version: tool returned before its startup result settled: $(cat "$FM_HOME/state/.startup-network.status")"
[ ! -e "$FM_HOME/state/.lock.acquire" ] || fail "$version: tool returned with an acquisition claim"
[ "$(cat "$FM_HOME/state/.session-start-complete")" = "$identity" ] \
  || fail "$version: completed startup lost its generation"
fm_session_lock_owned_by_self "$FM_HOME/state" || fail "$version: completed startup lost ownership"
pass "$version: real tool startup completed, published its result and released its claim"
