#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

# Lavish owns this persisted session contract. The fake CLI fixtures exercise
# its published poll and synchronous reply command boundaries without starting a server.
lavish_session() {  # <artifact> [session-url]
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "${2:-http://127.0.0.1:14387/session/0123456789abcdef}"
}

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule. The wait is bounded so a stub that
# escapes its test cannot keep spawning processes indefinitely.
trigger=$1; shift
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

# Records that the wrapped command actually started, then becomes it. A claim
# only proves its runner got as far as claiming; a test that needs the runner
# already inside its source command waits for this marker instead of a settle
# window, because a runner still short of that command retires itself when its
# registration goes away.
STARTED_BLOCKER="$TMP_ROOT/started-blocker.sh"
cat > "$STARTED_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$1"
shift
exec "$@"
SH
chmod +x "$STARTED_BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every home this suite registers a source in is tracked so teardown can stop
# its runners. A runner started by reconcile is detached and reparented, so a
# source that never completes outlives the suite unless its home is swept -
# removing the fixture directory does not stop an already-running child.
# tests/lib.sh owns that sweep and runs it from every cleanup path.
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  fm_test_track_procevent_home "$home"
  pe "$home" register "$adapter" "$id" "$@"
}
new_home() { mkdir -p "$1/state"; }
# A worker-owned board can only be armed for a task whose endpoint metadata the
# runner can ring, so every fixture worker needs the same durable record a real
# spawn leaves behind.
new_task_endpoint() {  # <home> <task-id>
  mkdir -p "$1/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" \
    > "$1/state/$2.meta"
}
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# The wake queue is a durable tab-separated record firstmate consumes:
# <epoch> <sequence> <kind> <key> <payload>. These read the rows reconcile
# publishes for a source it stranded, keyed by that source and its claim
# generation.
stranded_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
stranded_wake_count() {  # <home> <source-id>
  stranded_wake_keys "$1" "$2" | grep -c . || true
}
stranded_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}
# The same rows for a launch reconcile could not confirm, keyed by that source
# and the registration identity the launch ran under.
launch_failed_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":launch-failed:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
launch_failed_wake_count() {  # <home> <source-id>
  launch_failed_wake_keys "$1" "$2" | grep -c . || true
}
launch_failed_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":launch-failed:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# Arm now starts the listener, so a later start would poll again. Wait for the
# capture that listener is already producing, and for its runner to release the
# claim: the result lands before the runner publishes and exits, and a retire or
# re-arm in that gap meets a live claim the synchronous start never left behind.
wait_capture() {  # <home> <source-id> [tries]
  local home=$1 id=$2 n=${3:-100}
  local _
  for _ in $(seq 1 "$n"); do
    if first_result "$home" "$id" >/dev/null 2>&1 \
      && [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# <file> <count> [tries]: wait until <file> holds at least <count> lines. A
# detached runner appends its execution marker after the command that started it
# has already returned, so a caller that needs that append must wait for it
# rather than assume a fixed settle window covered it on a loaded machine.
wait_for_lines() {
  local f=$1 want=$2 n=${3:-100} have
  for _ in $(seq 1 "$n"); do
    if [ -f "$f" ]; then
      have=$(wc -l < "$f" | tr -d ' ')
    else
      have=0
    fi
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

hold_source_lock() {  # <source-id> <ready-file> <release-file>
  local id=$1 ready=$2 release=$3 parent=$$
  FM_HOME="$TMP_ROOT/lock-helper-home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do
      kill -0 "$5" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$id" "$ready" "$release" "$parent" &
  HOLDER_PID=$!
}

hold_source_lock_then_handle() {  # <home> <source-id> <sequence> <ready-file> <release-file>
  local home=$1 id=$2 seq=$3 ready=$4 release=$5 parent=$$
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$4"
    while [ ! -e "$5" ]; do
      kill -0 "$6" 2>/dev/null || exit 1
      sleep 0.02
    done
    fm_procevent_mark_handled "$3/state" "$2" "$7"
  ' _ "$ROOT" "$id" "$home" "$ready" "$release" "$parent" "$seq" &
  HOLDER_PID=$!
}

qualify_fixture_claim() {
  local claim=$1 namespace=''
  if [ "$(uname)" = Linux ]; then
    namespace=$(bash -c '. "$1/bin/fm-process-identity-lib.sh"; fm_process_namespace' _ "$ROOT") \
      || fail "cannot read fixture process namespace"
  fi
  awk -v fixture_namespace="$namespace" '
    { lines[NR]=$0 }
    END {
      for (i=1; i<=12; i++) print i == 7 && lines[i] == "" ? "active" : lines[i]
      print fixture_namespace
    }
  ' "$claim" > "$claim.tmp" && mv "$claim.tmp" "$claim"
}

test_claim_namespaces() {
  [ "$(uname)" = Linux ] || { printf 'skip - Linux process-event claim namespace fixtures\n'; return 0; }
  local home="$TMP_ROOT/namespace-home" id=namespace-src claim saved token stage reservation
  local mode out namespace result
  new_home "$home"
  trap '
    if [ -f "$TMP_ROOT/namespace-home/original.claim" ] && [ -f "$FM_PROCEVENT_CLAIM_ROOT/namespace-src.claim" ]; then
      cp "$TMP_ROOT/namespace-home/original.claim" "$FM_PROCEVENT_CLAIM_ROOT/namespace-src.claim"
    fi
    touch "$TMP_ROOT/namespace-home/release"
    fm_test_cleanup
  ' EXIT
  cat > "$home/source.sh" <<'SH'
#!/usr/bin/env bash
printf 'feedback before checkpoint\n'
while [ ! -e "$1" ]; do
  [ "$SECONDS" -lt 120 ] || exit 75
  sleep 0.05
done
printf 'feedback after checkpoint\n'
SH
  chmod +x "$home/source.sh"
  pe_register "$home" lavish "$id" -- "$home/source.sh" "$home/release" >/dev/null
  pe "$home" reconcile >/dev/null || fail "namespace fixture did not start"
  claim="$FM_PROCEVENT_CLAIM_ROOT/$id.claim"
  wait_for "$claim" || fail "namespace fixture did not claim its source"
  saved="$home/original.claim"
  cp "$claim" "$saved"
  token=$(sed -n '3p' "$saved")
  namespace=$(bash -c '. "$1/bin/fm-process-identity-lib.sh"; fm_process_namespace' _ "$ROOT")
  stage="$home/state/procevent/.$id.$token.output"
  wait_for "$stage" || fail "namespace fixture never streamed its captured feedback"
  cp "$stage" "$home/expected.output"
  cp "$home/state/procevent/$id.source" "$home/expected.source"
  mkdir -m 700 "$home/state/procevent-capture-reservations"
  reservation="$home/state/procevent-capture-reservations/.extension-capture-$token.pending.json"
  printf '{"pending":"captured feedback"}\n' > "$reservation"
  chmod 0600 "$reservation"
  cp "$reservation" "$home/expected.reservation"
  assert_contains "$(pe "$home" list)" live "local runner is live before namespace divergence"
  assert_contains "$(pe "$home" start "$id")" 'already owned' "same-namespace runner prevents duplicate polling"
  for mode in legacy-absent foreign-collision foreign-absent foreign-terminal; do
    awk -v mode="$mode" '
      NR == 2 && (mode == "foreign-absent" || mode == "legacy-absent") { print "999999"; next }
      NR == 7 && mode == "foreign-terminal" { print "terminal"; next }
      NR == 13 { if (mode != "legacy-absent") print "foreign-namespace"; next }
      { print }
    ' "$saved" > "$claim"
    chmod 0600 "$claim"
    cp "$claim" "$home/expected.claim"
    out=$(pe "$home" list)
    assert_contains "$out" uncertain "$mode owner liveness is unknown"
    out=$(pe "$home" reconcile) || fail "$mode reconciliation failed unexpectedly: $out"
    assert_contains "$out" 'started=0' "$mode reconciliation cannot replace the owner"
    assert_contains "$out" 'uncertain=1' "$mode reconciliation reports uncertainty"
    assert_contains "$(pe "$home" start "$id")" 'already owned' "$mode direct start preserves the owner"
    if pe "$home" retire "$id" > "$home/retire.out" 2>&1; then
      fail "$mode retirement accepted unavailable ownership proof"
    fi
    if pe "$home" sweep-home --preflight > "$home/sweep.out" 2>&1; then
      fail "$mode sweep preflight accepted unavailable ownership proof"
    fi
    cmp -s "$claim" "$home/expected.claim" || fail "$mode changed the durable claim"
    cmp -s "$stage" "$home/expected.output" || fail "$mode lost captured staging output"
    cmp -s "$reservation" "$home/expected.reservation" || fail "$mode lost a capture reservation"
    cmp -s "$home/state/procevent/$id.source" "$home/expected.source" || fail "$mode changed source registration"
  done
  [ "$(sed -n '13p' "$saved")" = "$namespace" ] \
    || fail "runner claim omitted its originating process namespace"
  rm "$home/state/procevent/$id.source"
  out=$(pe "$home" reconcile)
  assert_contains "$out" 'uncertain=1' 'unregistered foreign owner cannot be stopped'
  cmp -s "$claim" "$home/expected.claim" || fail "unregistered reconcile changed the foreign claim"
  cmp -s "$stage" "$home/expected.output" || fail "unregistered reconcile lost captured feedback"
  cp "$home/expected.source" "$home/state/procevent/$id.source"
  cp "$saved" "$claim"
  touch "$home/release"
  wait_capture "$home" "$id" || fail "preserved owner did not deliver its captured feedback"
  result=$(first_result "$home" "$id")
  assert_contains "$(cat "$result")" 'feedback before checkpoint' 'early feedback survives restricted reconciliation'
  assert_contains "$(cat "$result")" 'feedback after checkpoint' 'original runner completes after namespace proof is restored'
  awk 'NR == 2 { print "999999"; next } { print }' "$saved" > "$claim"
  printf 'abandoned staging output\n' > "$stage"
  out=$(pe "$home" start "$id") || fail "same-namespace dead generation could not be reclaimed: $out"
  assert_contains "$out" captured: 'same-namespace dead generation remains reclaimable'
  assert_absent "$stage" 'proved-dead staging output is removed'
  assert_absent "$claim" 'replacement releases its namespace-qualified claim'
  pe "$home" retire "$id" >/dev/null
  trap fm_test_cleanup EXIT
  pass 'namespace-qualified claims preserve unknown owners and captured feedback'
}

ORPHAN_STUB="$TMP_ROOT/orphan-stub.sh"
cat > "$ORPHAN_STUB" <<'SH'
#!/usr/bin/env bash
# A blocking source whose child keeps spawning processes, which is what a poll
# stub waiting on a trigger file actually does. The spawn rate is what turned a
# leftover listener into a host-wide storm, so the tick log is the evidence that
# the storm stopped and not merely that one pid went away.
marker=$1
( while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    printf 'tick\n' >> "$marker.ticks"
    sleep 0.1
  done ) &
printf '%s\n' "$!" > "$marker.descendant"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1
done
printf 'orphan payload\n'
SH
chmod +x "$ORPHAN_STUB"

# The same shape without the spawn churn, for the home that exercises explicit
# retirement rather than the storm. Retirement refuses instead of signalling
# when it cannot confirm the runner's identity, that identity is read through
# `ps`, and the churning stub above starves that read often enough to make a
# single retirement attempt a race. The storm itself is already covered against
# the churning stub by the owner-loss reaping above, which asserts the tick log
# stops, so this home only needs a reparented listener holding a real
# descendant in its group.
QUIET_STUB="$TMP_ROOT/quiet-stub.sh"
cat > "$QUIET_STUB" <<'SH'
#!/usr/bin/env bash
marker=$1
( sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ) &
printf '%s\n' "$!" > "$marker.descendant"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1
done
printf 'orphan payload\n'
SH
chmod +x "$QUIET_STUB"

# Short enough to observe, and driven through the same environment a real home
# uses, so the bound under test is the shipped one rather than a test-only path.
# One source of truth for the shortened lease and check these fixtures run under,
# so a case that derives a deadline from the guard's documented bound cannot
# silently diverge from the settings the guard is actually given.
PROOF_LEASE_SECONDS=2
PROOF_CHECK_SECONDS=1

# The documented bound, derived here rather than restated as a flat number.
#
# The whole-second lease comparison is part of the bound, not slack: a lease of
# N is honoured until its age reads N+1, so the lease term is N+1.
PROOF_LEASE_BOUND=$((PROOF_LEASE_SECONDS + 1))
# Detection is the lease plus ONE check interval. The guard still takes two
# consecutive failing reads before it acts - one unreadable read must not end a
# live runner - but they are spaced half an interval apart, so the pair fits
# inside the single interval this term budgets.
PROOF_DETECT_BOUND=$((PROOF_LEASE_BOUND + PROOF_CHECK_SECONDS))
# The stop's own ceiling: two seconds for the ordinary signal, then two for the
# forced one. Only a group that outlives the ordinary signal spends it, so a
# case whose stub exits on that signal uses PROOF_PROMPT_STOP instead.
PROOF_STOP_CEILING=4
PROOF_PROMPT_STOP=1
# Additive scheduling slack shared by cleanup and timing cases. The strict
# timing case below owns and enforces its relation to BOUND_CHECK_SECONDS.
PROOF_LOAD_SLACK=2

orphan_pe() {  # <home> <command...>
  local home=$1
  shift
  FM_PROCEVENT_OWNER_LEASE_SECONDS="$PROOF_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$PROOF_CHECK_SECONDS" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

wait_gone() {  # <pid-or-group-spec> [tries]
  local spec=$1 n=${2:-160}
  for _ in $(seq 1 "$n"); do
    kill -0 "$spec" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

HORPHAN="$TMP_ROOT/orphan-dead-owner"; new_home "$HORPHAN"
fm_test_track_procevent_home "$HORPHAN"
HKEEP="$TMP_ROOT/orphan-live-owner"; new_home "$HKEEP"
fm_test_track_procevent_home "$HKEEP"
orphan_pe "$HORPHAN" register lavish orphan-src -- "$ORPHAN_STUB" "$TMP_ROOT/orphan-dead" >/dev/null
orphan_pe "$HKEEP" register lavish keep-src -- "$QUIET_STUB" "$TMP_ROOT/orphan-live" >/dev/null
orphan_pe "$HORPHAN" reconcile >/dev/null
orphan_pe "$HKEEP" reconcile >/dev/null

wait_for "$HORPHAN/state/procevent/orphan-src.runner" \
  || fail "the dead-owner listener never recorded its runner"
wait_for "$HKEEP/state/procevent/keep-src.runner" \
  || fail "the live-owner listener never recorded its runner"
wait_for "$TMP_ROOT/orphan-dead.descendant" \
  || fail "the dead-owner listener's child never spawned its own descendant"
ORPHAN_PID=$(cat "$HORPHAN/state/procevent/orphan-src.runner")
KEEP_PID=$(cat "$HKEEP/state/procevent/keep-src.runner")
ORPHAN_DESCENDANT=$(cat "$TMP_ROOT/orphan-dead.descendant")

# The reproduction condition itself: the listener is already an orphan in the
# kernel's sense before anything is asserted about reaping it.
orphan_ppid=$(ps -o ppid= -p "$ORPHAN_PID" 2>/dev/null | tr -d '[:space:]')
[ "$orphan_ppid" = 1 ] \
  || fail "the listener under test was not reparented away from its session (ppid $orphan_ppid)"
kill -0 -"$ORPHAN_PID" 2>/dev/null \
  || fail "the listener's process group was not running"
kill -0 "$ORPHAN_DESCENDANT" 2>/dev/null \
  || fail "the listener's descendant was not running"
pass "a detached listener starts reparented, with a live descendant tree under it"

# Only the second home's session stays present, on the same short bound, so the
# owning session is the single difference between the two listeners.
keep_owner_present() { orphan_pe "$HKEEP" reconcile >/dev/null 2>&1 || true; sleep 0.25; }

# This stub exits on the ordinary signal, so the stop ceiling is not spent here.
# The deadline is DERIVED from the documented bound; the timing case below is
# the one that pins the bound's worst case, while this one asserts that the
# reaping happens at all and cannot quietly take an unbounded amount of time.
orphan_bound=$((PROOF_DETECT_BOUND + PROOF_PROMPT_STOP))
deadline=$((SECONDS + orphan_bound + PROOF_LOAD_SLACK))
orphan_started=$SECONDS
while kill -0 -"$ORPHAN_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "a listener whose owning session was gone kept its process group running for $((SECONDS - orphan_started))s, against a documented bound of ${orphan_bound}s"
  keep_owner_present
done
# The descendant goes down with the same group signal, so it needs no bound of
# its own beyond the slack that covers a loaded host.
deadline=$((SECONDS + PROOF_LOAD_SLACK))
while kill -0 "$ORPHAN_DESCENDANT" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "a listener whose owning session was gone left a descendant running"
  keep_owner_present
done
pass "a listener whose owning session is gone stops itself and its whole process group"

keep_owner_present
before=$(wc -l < "$TMP_ROOT/orphan-dead.ticks" | tr -d ' ')
deadline=$((SECONDS + 2))
while [ "$SECONDS" -lt "$deadline" ]; do keep_owner_present; done
after=$(wc -l < "$TMP_ROOT/orphan-dead.ticks" | tr -d ' ')
[ "$before" = "$after" ] \
  || fail "the reaped listener's descendant kept spawning processes ($before then $after)"
pass "reaping the listener stops the process churn under it"

keep_owner_present
kill -0 -"$KEEP_PID" 2>/dev/null \
  || fail "an identical listener in a home whose session is still there was reaped too"
pass "an identical listener in a home whose session is still there is untouched"

# Retirement remains the explicit path, and it must reach a listener that has
# already reparented, along with everything under it.
wait_for "$TMP_ROOT/orphan-live.descendant" \
  || fail "the live-owner listener's child never spawned its own descendant"
KEEP_DESCENDANT=$(cat "$TMP_ROOT/orphan-live.descendant")
keep_owner_present
orphan_pe "$HKEEP" retire keep-src >/dev/null
wait_gone "-$KEEP_PID" \
  || fail "retiring a source left its reparented listener's process group running"
wait_gone "$KEEP_DESCENDANT" \
  || fail "retiring a source left a descendant of its listener running"
pass "retiring a source reaps its reparented listener and every descendant under it"

