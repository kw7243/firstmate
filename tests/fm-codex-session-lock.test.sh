#!/usr/bin/env bash
# Behavioral Linux ownership tests with real process ancestry. The copied bash
# executable supplies a portable Codex-shaped boundary, not vendor evidence;
# actual Codex verification is recorded in docs/verification/runtime-backends.md.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -d /proc/self/ns ] || { printf '# skip: Linux process namespaces unavailable\n'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-codex-session)
cp /bin/bash "$TMP_ROOT/codex"
mkdir -p "$TMP_ROOT/home/state"
export FM_HOME="$TMP_ROOT/home" ROOT
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE CLAUDE_PID CLAUDE_CODE_SESSION_ID
first=11111111-1111-4111-8111-111111111111
second=22222222-2222-4222-8222-222222222222

# Force a separate tool child and keep the native-shaped parent alive across
# it. Its own environment deliberately carries a different inherited id.
run_tool() {
  # shellcheck disable=SC2016 # Expand in the fixture tool boundary.
  CODEX_THREAD_ID=33333333-3333-4333-8333-333333333333 \
    "$TMP_ROOT/codex" -c 'CODEX_THREAD_ID=$1 bash "$2" "${@:3}"; result=$?; exit "$result"' _ "$1" "$2" "${@:3}"
}

cat > "$TMP_ROOT/acquire.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
expected="codex:$CODEX_THREAD_ID"
[ "$(fm_session_lock_trusted_codex_session_id)" = "$expected" ]
if CODEX_THREAD_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa fm_session_lock_trusted_codex_session_id; then
  exit 10
fi
bash "$ROOT/bin/fm-lock.sh"
fm_session_lock_owned_by_self "$FM_HOME/state"
[ "$(fm_session_lock_generation "$FM_HOME/state")" = "$expected" ]
printf '%s\n' ready > "$FM_HOME/ready"
for ((i=0; i<300; i++)); do
  [ ! -e "$FM_HOME/finish" ] || exit 0
  sleep 0.1
done
exit 11
TOOL
run_tool "$first" "$TMP_ROOT/acquire.sh" > "$TMP_ROOT/first.out" 2>&1 &
owner=$!
trap 'touch "$FM_HOME/finish"; wait "$owner" 2>/dev/null || true; fm_test_cleanup' EXIT
for ((i=0; i<200; i++)); do
  [ ! -e "$FM_HOME/ready" ] || break
  sleep 0.05
done
[ -e "$FM_HOME/ready" ] || fail "first process did not acquire: $(cat "$TMP_ROOT/first.out")"
cp "$FM_HOME/state/.lock" "$TMP_ROOT/pid-before"
cp "$FM_HOME/state/.lock-session" "$TMP_ROOT/session-before"

cat > "$TMP_ROOT/refuse.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
if bash "$ROOT/bin/fm-lock.sh"; then exit 20; fi
if fm_session_lock_owned_by_self "$FM_HOME/state"; then exit 21; fi
fm_session_lock_inspect "$FM_HOME/state"
[ "$FM_LOCK_INSPECT_STATE" = held ]
TOOL
run_tool "$second" "$TMP_ROOT/refuse.sh" > "$TMP_ROOT/refuse.out" 2>&1 \
  || fail "competing live thread was not refused: $(cat "$TMP_ROOT/refuse.out")"
cmp -s "$TMP_ROOT/pid-before" "$FM_HOME/state/.lock" || fail 'refusal changed owner PID'
cmp -s "$TMP_ROOT/session-before" "$FM_HOME/state/.lock-session" || fail 'refusal changed owner identity'
pass 'Codex identity comes from the tool boundary, rejects override and excludes a competing live session'

touch "$FM_HOME/finish"
wait "$owner" || fail 'first fixture failed'
trap fm_test_cleanup EXIT
cat > "$TMP_ROOT/reclaim.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_session_lock_inspect "$FM_HOME/state"
[ "$FM_LOCK_INSPECT_STATE" = stale ]
bash "$ROOT/bin/fm-lock.sh"
fm_session_lock_owned_by_self "$FM_HOME/state"
before=$(fm_session_lock_generation "$FM_HOME/state")
bash "$ROOT/bin/fm-lock.sh"
[ "$(fm_session_lock_generation "$FM_HOME/state")" = "$before" ]
# Derivative state follows the stable generation across anchor refresh.
. "$ROOT/bin/fm-trace-context-lib.sh"
mkdir -p "$FM_HOME/config"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
[ "$(fm_trace_context_session_lock "$FM_HOME/state/.trace-context-effective")" = "$before" ]
bash "$ROOT/bin/fm-lease.sh" claim sample
bash "$ROOT/bin/fm-lease.sh" check sample | grep -q ' live$'
# Changing only the recorded namespace makes liveness unknowable to a foreign
# session. This is a negative fixture, not a simulated real sandbox pass.
python3 - "$FM_HOME/state/.lock-session" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
fields = lines[1].split()
fields[2] = 'different-boot/pid:[999999]'
p.write_text(lines[0] + '\n' + ' '.join(fields) + '\n')
PY
TOOL
run_tool "$second" "$TMP_ROOT/reclaim.sh" > "$TMP_ROOT/reclaim.out" 2>&1 \
  || fail "dead owner/reentry failed: $(cat "$TMP_ROOT/reclaim.out")"
pass 'proved dead host owner can be replaced and repeated entry keeps its generation'

cat > "$TMP_ROOT/unknown.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_session_lock_inspect "$FM_HOME/state"
[ "$FM_LOCK_INSPECT_STATE" = unknown ]
if bash "$ROOT/bin/fm-lock.sh"; then exit 30; fi
# An old-looking record is still uncertain: age is never ownership evidence.
touch -t 200001010000 "$FM_HOME/state/.lock" "$FM_HOME/state/.lock-session"
if bash "$ROOT/bin/fm-lock.sh"; then exit 31; fi
FM_SUPERVISION_ACTOR=branch bash "$ROOT/bin/fm-lease.sh" claim sample && exit 32
exit 0
TOOL
run_tool "$first" "$TMP_ROOT/unknown.sh" > "$TMP_ROOT/unknown.out" 2>&1 \
  || fail "unknown owner was not protected: $(cat "$TMP_ROOT/unknown.out")"
pass 'foreign namespace and unknown leases remain protected regardless of age'

# The app-server shape: different threads share one actual Codex ancestor.
# A PID match must not let the second thread take the first thread's lock.
cat > "$TMP_ROOT/shared-acquire.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
bash "$ROOT/bin/fm-lock.sh"
fm_session_lock_owned_by_self "$FM_HOME/state"
TOOL
mkdir -p "$TMP_ROOT/shared-home/state"
# shellcheck disable=SC2016 # Each child gets its own injected identity.
FM_HOME="$TMP_ROOT/shared-home" "$TMP_ROOT/codex" -c '
  CODEX_THREAD_ID=$1 bash "$3/shared-acquire.sh" || exit 60
  CODEX_THREAD_ID=$2 bash "$3/refuse.sh" || exit 61
  CODEX_THREAD_ID=$1 bash "$3/shared-acquire.sh" || exit 62
  :
' _ "$first" "$second" "$TMP_ROOT" > "$TMP_ROOT/shared.out" 2>&1 \
  || fail "shared Codex PID confused competing threads: $(cat "$TMP_ROOT/shared.out")"
pass "distinct threads sharing one Codex process cannot take each other's lock"

mkdir -p "$TMP_ROOT/reemit-root/bin" "$TMP_ROOT/reemit-home/state"
for script in "$ROOT"/bin/*.sh; do
  ln -s "$script" "$TMP_ROOT/reemit-root/bin/${script##*/}"
done
ln -s "$ROOT/docs" "$TMP_ROOT/reemit-root/docs"
rm "$TMP_ROOT/reemit-root/bin/fm-bootstrap.sh"
cat > "$TMP_ROOT/reemit-root/bin/fm-bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -eu
[ "${FM_BOOTSTRAP_NETWORK:-}" = only ] || exit 0
touch "$FM_HOME/sweeping"
while [ ! -e "$FM_HOME/release" ]; do sleep 0.1; done
BOOTSTRAP
chmod +x "$TMP_ROOT/reemit-root/bin/fm-bootstrap.sh"
cat > "$TMP_ROOT/start-sweep.sh" <<'TOOL'
set -eu
bash "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"
bash "$FM_ROOT_OVERRIDE/bin/fm-startup-network.sh" start --locked 1 --harvest-pid 0
for ((i=0; i<100; i++)); do
  [ ! -e "$FM_HOME/sweeping" ] || exit 0
  sleep 0.1
done
exit 70
TOOL
cat > "$TMP_ROOT/reemit.sh" <<'TOOL'
set -eu
touch "$FM_HOME/reentering"
bash "$FM_ROOT_OVERRIDE/bin/fm-session-start.sh" --reemit
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$FM_HOME/state"
[ "$(fm_session_lock_generation "$FM_HOME/state")" = "codex:$CODEX_THREAD_ID" ]
touch "$FM_HOME/reentered"
TOOL
cat > "$TMP_ROOT/refuse-sweep.sh" <<'TOOL'
set -eu
if bash "$ROOT/bin/fm-lock.sh"; then exit 71; fi
TOOL
(
  export FM_HOME="$TMP_ROOT/reemit-home" FM_ROOT_OVERRIDE="$TMP_ROOT/reemit-root"
  reentry=
  trap 'touch "$FM_HOME/release"; [ -z "$reentry" ] || wait "$reentry" 2>/dev/null || true' EXIT
  run_tool "$first" "$TMP_ROOT/start-sweep.sh" > "$TMP_ROOT/start-sweep.out" 2>&1 \
    || fail "could not start an owned sweep: $(cat "$TMP_ROOT/start-sweep.out")"
  cp "$FM_HOME/state/.lock" "$TMP_ROOT/sweep-pid-before"
  cp "$FM_HOME/state/.lock-session" "$TMP_ROOT/sweep-session-before"
  [ -s "$FM_HOME/state/.lock.acquire/pid" ] || fail 'sweep did not hold the acquisition claim'
  run_tool "$first" "$TMP_ROOT/reemit.sh" > "$TMP_ROOT/reemit.out" 2>&1 &
  reentry=$!
  for ((i=0; i<100; i++)); do
    [ ! -e "$FM_HOME/reentering" ] || break
    sleep 0.1
  done
  [ -e "$FM_HOME/reentering" ] || fail 'repeat entry never started'
  for ((i=0; i<100; i++)); do
    if grep -qx LOCK "$TMP_ROOT/reemit.out"; then break; fi
    sleep 0.1
  done
  grep -qx LOCK "$TMP_ROOT/reemit.out" \
    || fail "reemit did not reach lock acquisition: $(cat "$TMP_ROOT/reemit.out")"
  sleep 1
  run_tool "$second" "$TMP_ROOT/refuse-sweep.sh" > "$TMP_ROOT/refuse-sweep.out" 2>&1 \
    || fail "competing session entered during the sweep: $(cat "$TMP_ROOT/refuse-sweep.out")"
  for ((i=0; i<100; i++)); do
    if grep -q 'READ-ONLY SESSION' "$TMP_ROOT/reemit.out" || [ -e "$FM_HOME/reentered" ]; then break; fi
    sleep 0.1
  done
  kill -0 "$reentry" 2>/dev/null || fail "repeat entry exited during the sweep: $(cat "$TMP_ROOT/reemit.out")"
  cmp -s "$TMP_ROOT/sweep-pid-before" "$FM_HOME/state/.lock" || fail 'repeat entry rewrote a leased anchor'
  cmp -s "$TMP_ROOT/sweep-session-before" "$FM_HOME/state/.lock-session" || fail 'repeat entry rewrote leased coordinates'
  touch "$FM_HOME/release"
  wait "$reentry" || fail "repeat entry failed: $(cat "$TMP_ROOT/reemit.out")"
  reentry=
  [ -e "$FM_HOME/reentered" ] || fail 'repeat entry did not retain ownership'
  assert_not_contains "$(cat "$TMP_ROOT/reemit.out")" 'READ-ONLY SESSION' 'owned reemit became read-only'
  assert_not_contains "$(cat "$TMP_ROOT/reemit.out")" '●  STARTUP TRUNCATED' 'owned reemit did not finish'
  if cmp -s "$TMP_ROOT/sweep-pid-before" "$FM_HOME/state/.lock"; then fail 'Codex anchor was not refreshed'; fi
  bash "$FM_ROOT_OVERRIDE/bin/fm-startup-network.sh" wait 10 >/dev/null || fail 'sweep did not publish'
)
pass 'Codex reemit waits for its own sweep, refreshes coordinates, and refuses a competing session'

# An unannotated PID 1 is never ownership evidence for a native Codex call.
printf '1\n' > "$FM_HOME/state/.lock"
rm "$FM_HOME/state/.lock-session"
cat > "$TMP_ROOT/legacy.sh" <<'TOOL'
set -eu
. "$ROOT/bin/fm-session-lock-lib.sh"
if fm_session_lock_owned_by_self "$FM_HOME/state"; then exit 40; fi
if bash "$ROOT/bin/fm-lock.sh"; then exit 41; fi
TOOL
run_tool "$first" "$TMP_ROOT/legacy.sh" > "$TMP_ROOT/legacy.out" 2>&1 \
  || fail "unqualified PID 1 became self-owned: $(cat "$TMP_ROOT/legacy.out")"
pass 'bare PID 1 is refused without a verified session record'

# Exercise the real shared mutex: a colliding PID in foreign coordinates may
# neither reacquire nor release it, and missing coordinates cannot prove death.
FM_STATE_OVERRIDE="$TMP_ROOT/mutex-state" bash -s -- "$ROOT" "$TMP_ROOT/mutex" <<'MUTEX'
set -eu
. "$1/bin/fm-wake-lib.sh"
lock=$2
fm_lock_try_acquire "$lock"
scope=$(cat "$lock/pid-namespace")
printf 'different-boot/pid:[999999]\n' > "$lock/pid-namespace"
if fm_lock_try_acquire "$lock"; then exit 50; fi
fm_lock_release "$lock"
[ -e "$lock/pid" ]
printf '%s\n' "$scope" > "$lock/pid-namespace"
fm_lock_release "$lock"
[ ! -e "$lock" ]
mkdir "$lock"
printf '99999999\n' > "$lock/pid"
touch -t 200001010000 "$lock"
if fm_lock_try_acquire "$lock"; then exit 51; fi
[ "$(cat "$lock/pid")" = 99999999 ]
MUTEX
pass 'transient mutex never steals or releases a foreign or unqualified namespace owner'
