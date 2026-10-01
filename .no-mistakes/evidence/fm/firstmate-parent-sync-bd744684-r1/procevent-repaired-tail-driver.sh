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

printf "Selected original suite tail: orphan ownership through final Lavish readiness checks\n"
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
# Both owners stay present while the two listeners start. Only the assertions
# below end the orphan's ownership; a loaded startup must not spend its lease.
(
  . "$ROOT/bin/fm-procevent-lib.sh"
  deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    fm_procevent_owner_lease_touch "$HORPHAN/state" || true
    fm_procevent_owner_lease_touch "$HKEEP/state" || true
    sleep 0.25
  done
) &
ORPHAN_SETUP_KEEPER=$!
trap 'kill "$ORPHAN_SETUP_KEEPER" 2>/dev/null || true; wait "$ORPHAN_SETUP_KEEPER" 2>/dev/null || true; fm_test_cleanup' EXIT
orphan_pe "$HORPHAN" reconcile >/dev/null
orphan_pe "$HKEEP" reconcile >/dev/null

wait_for "$HORPHAN/state/procevent/orphan-src.runner" \
  || fail "the dead-owner listener never recorded its runner"
wait_for "$HKEEP/state/procevent/keep-src.runner" \
  || fail "the live-owner listener never recorded its runner"
wait_for "$TMP_ROOT/orphan-dead.descendant" \
  || fail "the dead-owner listener's child never spawned its own descendant"
wait_for "$TMP_ROOT/orphan-live.descendant" \
  || fail "the live-owner listener's child never spawned its own descendant"
ORPHAN_PID=$(cat "$HORPHAN/state/procevent/orphan-src.runner")
KEEP_PID=$(cat "$HKEEP/state/procevent/keep-src.runner")
ORPHAN_DESCENDANT=$(cat "$TMP_ROOT/orphan-dead.descendant")

# Measure this session's orphan adopter independently: a service subreaper can
# adopt the detached child instead of PID 1. The probe's parent is waited for,
# and its child exits after observing adoption or a bounded five-second wait.
orphan_adopter=$(perl -e '
  defined(my $parent = fork) or exit 1;
  if ($parent) { waitpid($parent, 0) == $parent or exit 1; exit($? >> 8); }
  my $original_parent = $$;
  defined(my $child = fork) or exit 1;
  exit 0 if $child;
  my $deadline = time + 5;
  while (getppid() == $original_parent && time < $deadline) {
    select undef, undef, undef, 0.05;
  }
  getppid() != $original_parent or exit 1;
  print getppid(), "\n";
') || fail "could not observe this session's orphan adopter"
case "$orphan_adopter" in ''|*[!0-9]*) fail "the orphan adopter probe did not finish" ;; esac
# The listener must already have left its invoking session before reaping it.
orphan_ppid=$(ps -o ppid= -p "$ORPHAN_PID" 2>/dev/null | tr -d '[:space:]')
[ "$orphan_ppid" = "$orphan_adopter" ] \
  || fail "the listener under test was not reparented away from its session (ppid $orphan_ppid)"
kill -0 -"$ORPHAN_PID" 2>/dev/null \
  || fail "the listener's process group was not running"
kill -0 "$ORPHAN_DESCENDANT" 2>/dev/null \
  || fail "the listener's descendant was not running"
kill "$ORPHAN_SETUP_KEEPER" 2>/dev/null || true
wait "$ORPHAN_SETUP_KEEPER" 2>/dev/null || true
trap fm_test_cleanup EXIT
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

# --- an expired runner's guard retries unproved cleanup ---------------------
#
# A stop the guard cannot PROVE must not end the guard. A descendant still
# finishing uninterruptible work outlives even the group KILL, and a guard that
# gave up after one attempt would walk away from a still-running expired runner.
#
# The unprovable attempt is injected through the signal the real path actually
# reads: `ps` answers ONE process-group query for the runner with a group it
# does not lead, which is exactly how a stop that cannot be proved is reported.
# Every other `ps` call, and every later one, is the real command.

RETRY_HOME="$TMP_ROOT/stop-retry"; new_home "$RETRY_HOME"
fm_test_track_procevent_home "$RETRY_HOME"
RETRY_STATE="$TMP_ROOT/stop-retry-state"; mkdir -p "$RETRY_STATE"
RETRY_BIN=$(fm_fakebin "$TMP_ROOT/stop-retry-bin")
REAL_PS=$(command -v ps) || fail "this host has no ps to build the retry fixture on"
cat > "$RETRY_BIN/ps" <<SH
#!/usr/bin/env bash
if [ "\$1" = -o ] && [ "\$2" = "pgid=" ] && [ "\$3" = -p ] \\
  && [ -s "\$STOP_RETRY_STATE/target" ] \\
  && [ "\$4" = "\$(cat "\$STOP_RETRY_STATE/target")" ] \\
  && [ ! -e "\$STOP_RETRY_STATE/spent" ]; then
  : > "\$STOP_RETRY_STATE/spent"
  printf ' 999999\n'
  exit 0
fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$RETRY_BIN/ps"

retry_pe() {  # <command...>
  PATH="$RETRY_BIN:$PATH" STOP_RETRY_STATE="$RETRY_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS=2 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
    FM_HOME="$RETRY_HOME" "$ROOT/bin/fm-procevent.sh" "$@"
}

retry_pe register lavish retry-src -- "$ORPHAN_STUB" "$TMP_ROOT/stop-retry-marker" >/dev/null
retry_pe reconcile >/dev/null
wait_for "$RETRY_HOME/state/procevent/retry-src.runner" \
  || fail "the retry listener never recorded its runner"
RETRY_PID=$(cat "$RETRY_HOME/state/procevent/retry-src.runner")
# Armed only now: the runner already proved its own process group at startup,
# and arming earlier would fail that assertion instead of the stop under test.
printf '%s\n' "$RETRY_PID" > "$RETRY_STATE/target"
wait_for "$TMP_ROOT/stop-retry-marker.descendant" \
  || fail "the retry listener's child never spawned its own descendant"
RETRY_DESCENDANT=$(cat "$TMP_ROOT/stop-retry-marker.descendant")

deadline=$((SECONDS + 60))
while kill -0 -"$RETRY_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "the guard gave up on an expired runner after a stop it could not prove"
  sleep 0.5
done
[ -e "$RETRY_STATE/spent" ] \
  || fail "the unprovable stop attempt this test injects never happened"
wait_gone "$RETRY_DESCENDANT" \
  || fail "the guard stopped retrying before the expired runner's descendant was reaped"
pass "a stop the guard cannot prove is retried until the expired runner is reaped"

# --- a stop reaches a child that does not die on the ordinary signal ---------
#
# Every reaper here sends the ordinary stop signal to the runner's process group
# and escalates only if the group outlives it. Both halves of that escalation
# were broken, in ways that hid each other:
#
#   - The stop held the per-source lock across its wait while the runner's own
#     exit cleanup waited for that same lock, so the runner outlived the ordinary
#     signal every time and the forced kill silently became the normal path.
#   - The escalation re-derived ownership from the leader, so once the leader did
#     die to the stop's own signal it read that success as a leaderless group and
#     refused to escalate at all.
#
# With only the first repaired, the second turned every stop of a signal-proof
# child into a refusal that left it running. They are asserted together because
# they only hold together.
#
# Earlier fixtures include TERM-resistant children and deliberately kept-alive
# leaders. The cases below also exercise escalation after TERM ends the leader.

# Millisecond clock for supplementary retirement and stop-window measurements;
# the healthy-stop verdict below requires attached-start status 143 (TERM).
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

SIGNAL_PROOF_STUB="$TMP_ROOT/signal-proof-stub.sh"
cat > "$SIGNAL_PROOF_STUB" <<'SH'
#!/usr/bin/env bash
# A blocking source whose child handles the ordinary stop signal and keeps
# waiting - the shape a poll client with its own shutdown handler presents while
# a request is still outstanding. Reaching it requires a real escalation. The
# signal log is what proves the child was signalled and survived, rather than
# never having been signalled at all. The wait stays bounded so an escaped stub
# cannot outlive the suite.
marker=$1
trap 'printf "signalled\n" >> "$marker.signals"' TERM INT HUP
printf '%s\n' "$$" > "$marker.child"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1 &
  wait $!
done
printf 'signal-proof payload\n'
SH
chmod +x "$SIGNAL_PROOF_STUB"

trap '[ -z "${PROOF_RELEASE:-}" ] || touch "$PROOF_RELEASE"; fm_test_cleanup' EXIT
for proof_state in absent zombie; do
  HPROOF="$TMP_ROOT/signal-proof-retire-$proof_state"; new_home "$HPROOF"
  PROOF_MARKER="$HPROOF/poll"
  pe_register "$HPROOF" lavish proof-src -- "$SIGNAL_PROOF_STUB" "$PROOF_MARKER" >/dev/null
  PROOF_RELEASE=
  if [ "$proof_state" = zombie ]; then
    PROOF_RELEASE="$HPROOF/reap"
    FM_HOME="$HPROOF" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
      perl - "$PROOF_RELEASE" "$ROOT/bin/fm-procevent.sh" _start proof-src >"$HPROOF/start.log" 2>&1 <<'PL' &
my $release = shift @ARGV;
defined(my $pid = fork) or exit 125;
if ($pid == 0) {
  setpgrp(0, 0) or exit 125;
  $ENV{FM_PROCEVENT_RUNNER_GROUP} = $$;
  exec @ARGV;
  exit 125;
}
my $deadline = time + ($ENV{FM_TEST_STUB_MAX_BLOCK_SECONDS} // 120);
while (!-e $release && time < $deadline) { select undef, undef, undef, 0.05; }
waitpid($pid, 0) == $pid or exit 125;
PL
  else
    FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
      pe "$HPROOF" start proof-src >"$HPROOF/start.log" 2>&1 &
  fi
  PROOF_START=$!
  wait_for "$HPROOF/state/procevent/proof-src.runner" \
    || fail "the signal-proof listener never recorded its runner"
  PROOF_PID=$(cat "$HPROOF/state/procevent/proof-src.runner")
  wait_for "$PROOF_MARKER.child" || fail "the signal-proof child never started"
  PROOF_CHILD=$(cat "$PROOF_MARKER.child")
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
    pe "$HPROOF" retire proof-src >"$HPROOF/retire.log" 2>&1 &
  PROOF_STOP=$!
  proof_transition=0
  for _ in $(seq 1 100); do
    if [ "$proof_state" = zombie ]; then
      case "$(ps -o stat= -p "$PROOF_PID" 2>/dev/null | tr -d '[:space:]')" in
        Z*) proof_transition=1; break ;;
      esac
    elif ! kill -0 "$PROOF_PID" 2>/dev/null; then
      proof_transition=1
      break
    fi
    sleep 0.05
  done
  proof_survivor=0
  kill -0 "$PROOF_CHILD" 2>/dev/null && proof_survivor=1
  proof_reaped=0
  for _ in $(seq 1 100); do
    if ! kill -0 "$PROOF_CHILD" 2>/dev/null; then proof_reaped=1; break; fi
    sleep 0.1
  done
  [ -z "$PROOF_RELEASE" ] || touch "$PROOF_RELEASE"
  PROOF_RELEASE=
  proof_status=0
  wait "$PROOF_STOP" || proof_status=$?
  [ "$proof_reaped" -eq 1 ] || kill -KILL -"$PROOF_PID" 2>/dev/null || true
  wait "$PROOF_START" 2>/dev/null || true
  [ "$proof_transition" -eq 1 ] || fail "the runner never became $proof_state after TERM"
  [ "$proof_survivor" -eq 1 ] || fail "no child survived the $proof_state leader's TERM"
  [ "$proof_reaped" -eq 1 ] || fail "escalation abandoned a child behind a $proof_state leader"
  [ "$proof_status" -eq 0 ] || fail "retiring the $proof_state leader's group reported failure"
  wait_gone "-$PROOF_PID" || fail "retirement left the $proof_state leader's group running"
  [ -s "$PROOF_MARKER.signals" ] || fail "the signal-proof child never received TERM"
  pass "retirement escalates after TERM leaves a surviving child ($proof_state leader)"
done
trap fm_test_cleanup EXIT

# --- the owner guard reaps a signal-proof child too --------------------------
#
# The guard is where the time bound on a leaked listener lives, so it is the half
# that matters most: a guard that signals, loses its leader to its own signal and
# then walks away leaves the survivor unreachable by anything at all - worse than
# no guard, because the leader it destroyed was the only proof of ownership left.

HPGUARD="$TMP_ROOT/signal-proof-guard"; new_home "$HPGUARD"
fm_test_track_procevent_home "$HPGUARD"
orphan_pe "$HPGUARD" register lavish proof-guard-src \
  -- "$SIGNAL_PROOF_STUB" "$TMP_ROOT/proof-guard" >/dev/null
orphan_pe "$HPGUARD" reconcile >/dev/null
# The owner is kept present until the fixture is fully up, because the input
# under test is an owner that GOES AWAY, not a runner that never finished
# starting: on a loaded host the short lease here can otherwise expire while the
# runner is still between fork and its first recorded state.
deadline=$((SECONDS + 60))
until [ -s "$HPGUARD/state/procevent/proof-guard-src.runner" ] \
  && [ -s "$TMP_ROOT/proof-guard.child" ]; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the guarded signal-proof listener never started"
  orphan_pe "$HPGUARD" reconcile >/dev/null 2>&1 || true
  sleep 0.25
done
GUARD_PID=$(cat "$HPGUARD/state/procevent/proof-guard-src.runner")
GUARD_CHILD=$(cat "$TMP_ROOT/proof-guard.child")

# Nothing refreshes this home's lease from here on, which is the whole input.
#
# The deadline is DERIVED from the bound this case exists to defend, not a flat
# wall-clock number. The documented bound is the lease term, plus ONE check
# interval for detection - the guard's two confirming reads are half an interval
# apart and both fit inside it - plus the stop's own grace, its ordinary signal
# window and then its forced one. THIS case does spend that grace, because its
# child ignores the ordinary signal; that is what separates its allowance from
# the ordinary-stop case above.
#
# This case bounds cleanup completion; the strict timing case below owns the
# phase and slack requirements that distinguish one check interval from two.
guard_bound=$((PROOF_DETECT_BOUND + PROOF_STOP_CEILING))
deadline=$((SECONDS + guard_bound + PROOF_LOAD_SLACK))
guard_started=$SECONDS
while kill -0 -"$GUARD_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "the guard exceeded its bound: still holding the group after $((SECONDS - guard_started))s, against a documented bound of ${guard_bound}s"
  sleep 0.5
done
wait_gone "$GUARD_CHILD" \
  || fail "the guard stopped at the leader and left the signal-proof child running"
[ -s "$TMP_ROOT/proof-guard.signals" ] \
  || fail "the guarded child was never signalled, so nothing about escalation was exercised"
pass "an expired runner's guard escalates past a signal-proof child"

# --- the guard's bound is one check interval, not two ------------------------
#
# The case above proves the guard reaps at all. This one measures HOW LONG it
# may take, because that is the number the operating contract states and the one
# a later change can quietly double.
#
# The bound: the lease term, plus ONE check interval. The guard still refuses to
# act on a single failed read - the debounce case below is what defends that -
# but its two confirming reads are spaced half an interval apart, so the pair
# fits inside the one interval budgeted here. A guard that put a whole interval
# between them would spend two, and this deadline is sized to catch exactly that.
#
# THE PHASE IS OBSERVED AND ENFORCED, NOT ASSUMED. Where the lease expiry falls
# relative to the guard's own check clock decides whether a run lands near the
# bound or well inside it, and a sampled phase would let a guard spending two
# intervals slip under this deadline on a lucky alignment. So the lease is
# synchronized to the guard's own FIRST observed lease read, every later real
# read is recorded, and the case then REFUSES unless one of those reads proves
# the required phase: fresh, before expiry, and late enough that two further
# full intervals could not finish before the deadline.
#
# Pinning the phase by construction instead - from an assumed startup time - is
# what an earlier version of this case did, and it is not enough: the day
# startup reaches two seconds it silently stops rejecting a two-interval guard
# and goes on passing. A bound that cannot fail for the reason it names is the
# defect this whole delivery exists to correct, so an unestablished precondition
# refuses here rather than proceeding on trust.
BOUND_LEASE_SECONDS=7
BOUND_CHECK_SECONDS=6
# The whole-second lease comparison is part of the bound, not slack: a lease of
# N is honoured until its age reads N+1.
bound_lease_term=$((BOUND_LEASE_SECONDS + 1))
bound_detect=$((bound_lease_term + BOUND_CHECK_SECONDS))
# This stub exits on the ordinary signal, so the stop's escalation ceiling is
# not spent here; one second covers signalling and exit against a measured
# ~0.4s for a whole retire command on this host.
bound_total=$((bound_detect + PROOF_PROMPT_STOP))
# Additive load slack, under half a check interval for the reason above. The
# invariant is asserted rather than left to a comment, because a later widening
# is exactly what would disarm the deadline below.
bound_deadline_s=$((bound_total + PROOF_LOAD_SLACK))
[ "$((PROOF_LOAD_SLACK * 2))" -lt "$BOUND_CHECK_SECONDS" ] \
  || fail "the bound fixture's load slack must stay below half a check interval"

now_mono() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.3f\n", clock_gettime(CLOCK_MONOTONIC)'
}
mono_since() {  # <monotonic-reference>: seconds elapsed, one decimal
  perl -e 'printf "%.1f\n", $ARGV[0] - $ARGV[1]' "$(now_mono)" "$1"
}

HBOUND="$TMP_ROOT/guard-bound"; new_home "$HBOUND"
fm_test_track_procevent_home "$HBOUND"
BOUND_STATE="$TMP_ROOT/guard-bound-state"; mkdir -p "$BOUND_STATE"
BOUND_BIN=$(fm_fakebin "$TMP_ROOT/guard-bound-bin")
REAL_PERL=$(command -v perl) || fail "this host has no perl to observe the guard's lease reads"
# Observes the real lease-age reads, identified by the lease-age program's own
# text, and changes nothing about what they return. The FIRST such read becomes
# the lease reference - that is the synchronization - and every later one is
# recorded with the value it read and the interval it spanned, which is the
# evidence the phase assertion below consumes.
cat > "$BOUND_BIN/perl" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in
    *'int(\$now - \$value)'*)
      started=\$("$REAL_PERL" -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \\
        'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)') || exit 1
      age=\$("$REAL_PERL" "\$@") || exit \$?
      finished=\$("$REAL_PERL" -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \\
        'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)') || exit 1
      if [ ! -s "\$GUARD_BOUND_STATE/reference" ]; then
        printf '%s\\n' "\$finished" > "\$FM_HOME/state/procevent/.owner-lease" || exit 1
        printf '%s\\n' "\$finished" > "\$GUARD_BOUND_STATE/reference" || exit 1
      else
        printf '%s\\t%s\\t%s\\t%s\\n' "\$started" "\$finished" "\$age" "\${!#}" \\
          >> "\$GUARD_BOUND_STATE/reads" || exit 1
      fi
      printf '%s\\n' "\$age"
      exit 0
      ;;
  esac
done
exec "$REAL_PERL" "\$@"
SH
chmod +x "$BOUND_BIN/perl"
bound_pe() {
  PATH="$BOUND_BIN:$PATH" GUARD_BOUND_STATE="$BOUND_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS="$BOUND_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$BOUND_CHECK_SECONDS" \
    FM_HOME="$HBOUND" "$ROOT/bin/fm-procevent.sh" "$@"
}
bound_pe register lavish bound-src -- "$QUIET_STUB" "$TMP_ROOT/guard-bound-marker" >/dev/null
bound_pe reconcile >/dev/null
wait_for "$HBOUND/state/procevent/bound-src.runner" \
  || fail "the bound fixture's listener never recorded its runner"
wait_for "$TMP_ROOT/guard-bound-marker.descendant" \
  || fail "the bound fixture's listener never spawned its descendant"
BOUND_PID=$(cat "$HBOUND/state/procevent/bound-src.runner")
BOUND_DESCENDANT=$(cat "$TMP_ROOT/guard-bound-marker.descendant")
# Elapsed is measured from the refresh the guard itself reads, not from a
# wall-clock moment near it, so the fixture's own startup cost cannot be
# mistaken for guard latency in either direction.
bound_reference=$(cat "$HBOUND/state/procevent/.owner-lease") \
  || fail "the bound fixture recorded no owner lease to measure against"
[ "$bound_reference" = "$(cat "$BOUND_STATE/reference" 2>/dev/null)" ] \
  || fail "the bound fixture did not synchronize its lease to an observed guard read"
while kill -0 -"$BOUND_PID" 2>/dev/null; do
  [ "$(mono_since "$bound_reference" | cut -d. -f1)" -lt "$bound_deadline_s" ] \
    || fail "the guard exceeded its bound: group still running $(mono_since "$bound_reference")s after the last owner activity, against a documented bound of ${bound_total}s (lease term ${bound_lease_term}s + one ${BOUND_CHECK_SECONDS}s check interval + ${PROOF_PROMPT_STOP}s stop)"
  sleep 0.2
done
bound_elapsed=$(mono_since "$bound_reference")
# The loop above only ever checks the clock while the group is still alive, so a
# sampler descheduled past the deadline would see the group already gone and
# report success. Check the OBSERVED completion time too: a late observation
# must not certify timely completion.
[ "${bound_elapsed%%.*}" -lt "$bound_deadline_s" ] \
  || fail "the guard's completion was first observed ${bound_elapsed}s after the last owner activity, beyond its ${bound_deadline_s}s deadline"
# FAIL CLOSED ON THE PHASE. One recorded read must prove the run was in the part
# of the interval this deadline can actually judge: it read the synchronized
# reference, it was still fresh (pre-expiry), and it began late enough that two
# further FULL intervals could not finish before the deadline. Without such a
# read the case refuses - it does not pass on trust, however quickly the group
# happened to stop.
perl - "$BOUND_STATE/reads" "$bound_reference" "$BOUND_LEASE_SECONDS" \
  "$BOUND_CHECK_SECONDS" "$bound_deadline_s" <<'PL' \
  || fail "the bound fixture could not establish the required pre-expiry guard-read phase"
use strict;
use warnings;
my ($path, $reference, $lease, $check, $deadline) = @ARGV;
open my $reads, '<', $path or exit 1;
while (<$reads>) {
  chomp;
  my ($started, $finished, $age, $value) = split /\t/;
  next unless defined $value && $value eq $reference && $age <= $lease;
  next unless $started >= $reference && $finished >= $started;
  next unless $finished < $reference + $lease + 1;
  next unless $started + 2 * $check >= $reference + $deadline;
  printf "guard phase: fresh read %.3f-%.3fs, expiry %ss, two full intervals could not finish before %.3fs (deadline %ss)\n",
    $started - $reference, $finished - $reference, $lease + 1,
    $started - $reference + 2 * $check, $deadline;
  exit 0;
}
exit 1;
PL
wait_gone "$BOUND_DESCENDANT" \
  || fail "the guard stopped at the leader and left its descendant running"
printf 'guard bound: lease=%ss check=%ss reaped %ss after the last owner activity, documented bound %ss\n' \
  "$BOUND_LEASE_SECONDS" "$BOUND_CHECK_SECONDS" "$bound_elapsed" "$bound_total"
pass "an orphaned runner is reaped within the lease plus ONE check interval"

# --- a zero-prefixed interval still starts a listener, and halves correctly ---
#
# OUR OWN REGRESSION, found in review before this change was published. The
# interval validator accepts a zero-prefixed value and `[` compares it as
# decimal, but the half-interval arithmetic introduced above reads `$(( ))`,
# which is octal for a leading zero: 010 halved to 4 instead of 5, and 08 was
# not a number at all, so the guard died before reporting ready and the runner
# failed closed and never listened.
#
# Asserted through the executable interface rather than by reading the source:
# a real listener is started at each value, and the guard's actual sleep
# argument is observed. Reading `10#` out of the script would prove nothing.
INTERVAL_BIN=$(fm_fakebin "$TMP_ROOT/decimal-interval-bin")
REAL_SLEEP=$(command -v sleep) || fail "this host has no sleep to observe guard intervals"
cat > "$INTERVAL_BIN/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$INTERVAL_SLEEP_LOG"
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$INTERVAL_BIN/sleep"
for interval in 08 010; do
  case "$interval" in
    08) expected_half=4 ;;
    010) expected_half=5 ;;
  esac
  HINTERVAL="$TMP_ROOT/decimal-interval-$interval"; new_home "$HINTERVAL"
  pe_register "$HINTERVAL" lavish "interval-$interval" \
    -- "$QUIET_STUB" "$HINTERVAL/poll" >/dev/null
  PATH="$INTERVAL_BIN:$PATH" INTERVAL_SLEEP_LOG="$HINTERVAL/sleeps" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$interval" \
    pe "$HINTERVAL" reconcile >/dev/null
  wait_for "$HINTERVAL/poll.descendant" \
    || fail "a zero-prefixed decimal interval ($interval) prevented the listener from starting"
  for _ in $(seq 1 100); do
    grep -qx "$expected_half" "$HINTERVAL/sleeps" 2>/dev/null && break
    sleep 0.1
  done
  grep -qx "$expected_half" "$HINTERVAL/sleeps" \
    || fail "the guard did not sleep half of the decimal interval $interval (expected ${expected_half}s)"
  pe "$HINTERVAL" retire "interval-$interval" >/dev/null \
    || fail "retiring the decimal-interval listener ($interval) reported failure"
  printf 'decimal interval: %s halves to %ss and its listener started\n' "$interval" "$expected_half"
done
pass "a zero-prefixed decimal interval starts its listener and halves as decimal"

# --- one unreadable read still does not end a live runner --------------------
#
# The bound above was tightened by moving the guard's two reads closer together,
# NOT by dropping the second one. This is what that second read is for, asserted
# separately so the two cannot be traded for each other by accident: against a
# home that is still alive, an isolated failed read must not stop the runner.
#
# The failure is injected where the real path actually reads. ONE lease read
# fails, exactly once, identified by the lease-age program's own text so no
# other call in the runner is touched; every read before and after it is the
# real command, and the home's lease stays long and fresh throughout. The single
# failed read is therefore the only thing wrong that the guard can see.

DEBOUNCE_HOME="$TMP_ROOT/lease-debounce"; new_home "$DEBOUNCE_HOME"
fm_test_track_procevent_home "$DEBOUNCE_HOME"
DEBOUNCE_STATE="$TMP_ROOT/lease-debounce-state"; mkdir -p "$DEBOUNCE_STATE"
DEBOUNCE_BIN=$(fm_fakebin "$TMP_ROOT/lease-debounce-bin")
REAL_PERL=$(command -v perl) || fail "this host has no perl to build the debounce fixture on"
cat > "$DEBOUNCE_BIN/perl" <<SH
#!/usr/bin/env bash
if [ -s "\$LEASE_DEBOUNCE_STATE/armed" ] && [ ! -s "\$LEASE_DEBOUNCE_STATE/spent" ]; then
  for arg in "\$@"; do
    case \$arg in
      *'int(\$now - \$value)'*)
        printf 'spent\n' > "\$LEASE_DEBOUNCE_STATE/spent"
        exit 1
        ;;
    esac
  done
fi
exec "$REAL_PERL" "\$@"
SH
chmod +x "$DEBOUNCE_BIN/perl"

# A long lease and a short check: many reads happen inside the observation
# window, and none of them can go stale on their own during it.
DEBOUNCE_LEASE_SECONDS=30
DEBOUNCE_CHECK_SECONDS=1
debounce_pe() {
  PATH="$DEBOUNCE_BIN:$PATH" LEASE_DEBOUNCE_STATE="$DEBOUNCE_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS="$DEBOUNCE_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$DEBOUNCE_CHECK_SECONDS" \
    FM_HOME="$DEBOUNCE_HOME" "$ROOT/bin/fm-procevent.sh" "$@"
}
debounce_pe register lavish debounce-src -- "$QUIET_STUB" "$TMP_ROOT/lease-debounce-marker" >/dev/null
debounce_pe reconcile >/dev/null
wait_for "$DEBOUNCE_HOME/state/procevent/debounce-src.runner" \
  || fail "the debounce fixture's listener never recorded its runner"
DEBOUNCE_PID=$(cat "$DEBOUNCE_HOME/state/procevent/debounce-src.runner")
# Armed only now. The guard proves the lease once before it reports ready, and
# failing THAT read would refuse the runner outright instead of exercising the
# debounce this case is about.
printf 'armed\n' > "$DEBOUNCE_STATE/armed"
wait_for "$DEBOUNCE_STATE/spent" \
  || fail "the single failed lease read this case injects never happened"
# Several further checks at the configured interval. A guard that acted on one
# failed read would have stopped the group during them.
sleep $((DEBOUNCE_CHECK_SECONDS * 4))
kill -0 -"$DEBOUNCE_PID" 2>/dev/null \
  || fail "one unreadable lease read ended a runner whose home was still alive"
debounce_pe retire debounce-src >/dev/null \
  || fail "retiring the debounce fixture's source reported failure"
wait_gone "-$DEBOUNCE_PID" \
  || fail "retiring the debounce fixture left its process group running"
pass "one unreadable read does not end a live runner"

# --- the ordinary stop signal is what stops a runner ------------------------
#
# The forced kill is the backstop, not the normal path. When it carries every
# stop, it stops being able to report that anything went wrong - which is exactly
# how a listener that could not be stopped looked identical to one that could.

HPROMPT="$TMP_ROOT/prompt-stop"; new_home "$HPROMPT"
pe_register "$HPROMPT" lavish prompt-src -- "$QUIET_STUB" "$TMP_ROOT/prompt-stop" >/dev/null
pe "$HPROMPT" start prompt-src >"$TMP_ROOT/prompt-start.log" 2>&1 &
PROMPT_START_PID=$!
wait_for "$HPROMPT/state/procevent/prompt-src.runner" \
  || fail "the promptly-stopping listener never recorded its runner"
PROMPT_PID=$(cat "$HPROMPT/state/procevent/prompt-src.runner")
wait_for "$TMP_ROOT/prompt-stop.descendant" \
  || fail "the promptly-stopping listener's child never spawned its own descendant"
stop_window_ms() {
  local from to
  from=$(now_ms)
  for _ in $(seq 1 20); do sleep 0.1; done
  to=$(now_ms)
  printf '%s\n' "$((to - from))"
}
window_before=$(stop_window_ms)
start=$(now_ms)
pe "$HPROMPT" retire prompt-src >/dev/null || fail "retiring a healthy listener reported failure"
elapsed=$(( $(now_ms) - start ))
window_after=$(stop_window_ms)
prompt_status=0
wait "$PROMPT_START_PID" || prompt_status=$?
wait_gone "-$PROMPT_PID" || fail "retiring a healthy listener left its process group running"
[ "$prompt_status" -eq 143 ] \
  || fail "the runner did not exit on TERM (start status=$prompt_status, retirement=${elapsed}ms, sampled windows=${window_before}/${window_after}ms)"
printf 'ordinary stop: start status=%s retirement=%sms sampled windows=%s/%sms\n' \
  "$prompt_status" "$elapsed" "$window_before" "$window_after"
pass "a runner exits on the ordinary stop signal instead of outliving it"

# --- a crashed leader's group is still refused -------------------------------
#
# The escalation above accepts a leaderless group in exactly one place: inside
# the stop that just proved and signalled that generation itself. Whether a group
# whose leader died to something ELSE may ever be signalled is a separate open
# question, and this pins that it stays refused - so the escalation cannot widen
# into an answer to it by accident.

HCRASH="$TMP_ROOT/crashed-leader"; new_home "$HCRASH"
pe_register "$HCRASH" lavish crash-src -- "$QUIET_STUB" "$TMP_ROOT/crash-leader" >/dev/null
pe "$HCRASH" reconcile >/dev/null
wait_for "$HCRASH/state/procevent/crash-src.runner" \
  || fail "the crash-fixture listener never recorded its runner"
CRASH_PID=$(cat "$HCRASH/state/procevent/crash-src.runner")
wait_for "$TMP_ROOT/crash-leader.descendant" \
  || fail "the crash-fixture listener's child never spawned its own descendant"
kill -KILL "$CRASH_PID" 2>/dev/null || fail "the crash fixture could not stop its own leader"
deadline=$((SECONDS + 10))
while kill -0 "$CRASH_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the crash fixture's leader never died"
  sleep 0.1
done
kill -0 -"$CRASH_PID" 2>/dev/null \
  || fail "the crash fixture left no surviving group, so nothing was refused"

out=$(pe "$HCRASH" retire crash-src 2>&1) && fail "retirement claimed success on a crashed leader's group"
assert_contains "$out" "cannot confirm runner identity" \
  "a crashed leader's group is refused with its own diagnostic"
assert_present "$HCRASH/state/procevent/crash-src.source" \
  "a refused retirement leaves the source registered"
kill -0 -"$CRASH_PID" 2>/dev/null \
  || fail "a refused retirement signalled the leaderless group anyway"
pass "a group whose leader died to something else is still refused, not signalled"
kill -KILL -"$CRASH_PID" 2>/dev/null || true

# --- arm reports ready only once this registration's listener is running ----
# The public arm path used to print armed as soon as registration was stored.
# A listener that has not claimed the source is not ready, so arm waits for the
# same live-claim or launch-stamp evidence reconcile uses and fails closed when
# that evidence does not appear within the confirm window.
READY="$TMP_ROOT/ready-arm"
mkdir -p "$READY/bin" "$READY/home/state"
cat > "$READY/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "${READY_MARK:?}"
while [ ! -e "${READY_RELEASE:?}" ]; do sleep 0.02; done
printf 'session:\n  status: ended\n'
SH
chmod +x "$READY/bin/lavish-axi"
ready_art="$READY/board.html"
printf '<h1>ready</h1>\n' > "$ready_art"
lavish_session "$ready_art"
ready_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ready_art")
fm_test_track_procevent_home "$READY/home"
export READY_MARK="$READY/mark" READY_RELEASE="$READY/release"
: > "$READY_MARK"
PATH="$READY/bin:$PATH" FM_HOME="$READY/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ready_art" > "$READY/arm.out"
assert_contains "$(cat "$READY/arm.out")" "armed: $ready_id" "a live listener was not reported ready"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/$ready_id.claim" ] \
  || fail "arm reported ready without a listener claim"
for _ in $(seq 1 50); do
  grep -q started "$READY_MARK" && break
  sleep 0.05
done
grep -q started "$READY_MARK" || fail "arm reported ready before the listener command ran"
touch "$READY_RELEASE"
for _ in $(seq 1 50); do
  [ -e "$FM_PROCEVENT_CLAIM_ROOT/$ready_id.claim" ] || break
  sleep 0.05
done
PATH="$READY/bin:$PATH" FM_HOME="$READY/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$ready_art" >/dev/null 2>&1 || true
pass "arm reports ready only after the listener is running"

# Delayed start: the source lock is held so the listener cannot claim, and arm
# must not print armed until that lock clears and the listener does.
DELAY="$TMP_ROOT/delay-arm"
mkdir -p "$DELAY/bin" "$DELAY/home/state"
cp "$READY/bin/lavish-axi" "$DELAY/bin/lavish-axi"
delay_art="$DELAY/board.html"
printf '<h1>delay</h1>\n' > "$delay_art"
lavish_session "$delay_art"
delay_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$delay_art")
fm_test_track_procevent_home "$DELAY/home"
export READY_MARK="$DELAY/mark" READY_RELEASE="$DELAY/release"
: > "$READY_MARK"
delay_ready="$DELAY/lock-ready"
delay_rel="$DELAY/lock-release"
hold_source_lock "$delay_id" "$delay_ready" "$delay_rel"
wait_for "$delay_ready" || fail "delayed-start fixture could not hold the source lock"
PATH="$DELAY/bin:$PATH" FM_HOME="$DELAY/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$delay_art" > "$DELAY/arm.out" 2>"$DELAY/arm.err" &
delay_arm=$!
sleep 0.4
assert_not_contains "$(cat "$DELAY/arm.out" 2>/dev/null || true)" "armed:" \
  "arm reported ready while the listener could not start"
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/$delay_id.claim" ] \
  || fail "a listener claimed the source while its lock was held"
touch "$delay_rel"
wait "$delay_arm" || fail "arm failed after the delayed listener was allowed to start: $(cat "$DELAY/arm.err")"
assert_contains "$(cat "$DELAY/arm.out")" "armed: $delay_id" \
  "arm did not report ready once the delayed listener was running"
for _ in $(seq 1 50); do
  grep -q started "$READY_MARK" && break
  sleep 0.05
done
grep -q started "$READY_MARK" || fail "the delayed listener never ran"
touch "$READY_RELEASE"
wait "$HOLDER_PID" 2>/dev/null || true
for _ in $(seq 1 50); do
  [ -e "$FM_PROCEVENT_CLAIM_ROOT/$delay_id.claim" ] || break
  sleep 0.05
done
PATH="$DELAY/bin:$PATH" FM_HOME="$DELAY/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$delay_art" >/dev/null 2>&1 || true
pass "arm waits out a delayed listener start before reporting ready"

# A claim path that is a directory can never be owned, so the runner dies before
# the listener command. Arm must not print ready, and it must remove the
# registration it just published.
arm_blocked_claim() {  # <dir> <confirm-seconds>
  local dir=$1 secs=$2 art id began rc elapsed
  mkdir -p "$dir/bin" "$dir/home/state"
  cat > "$dir/bin/lavish-axi" <<'SH'
#!/bin/sh
printf started >> "${READY_MARK:?}"
SH
  chmod +x "$dir/bin/lavish-axi"
  art="$dir/board.html"
  printf '<h1>blocked</h1>\n' > "$art"
  lavish_session "$art"
  id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")
  fm_test_track_procevent_home "$dir/home"
  mkdir -p "$FM_PROCEVENT_CLAIM_ROOT/$id.claim"
  export READY_MARK="$dir/mark"
  : > "$READY_MARK"
  began=$(date +%s)
  set +e
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS="$secs" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$art" > "$dir/arm.out" 2>"$dir/arm.err"
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - began ))
  [ "$rc" -ne 0 ] || fail "arm reported success when no listener could claim ($dir)"
  assert_not_contains "$(cat "$dir/arm.out")" "armed:" \
    "arm printed ready when no listener could claim ($dir)"
  [ ! -s "$READY_MARK" ] || fail "the listener command ran without a claim ($dir)"
  # retire refuses a claim it cannot read, and arm must not override it.
  [ -e "$dir/home/state/procevent/$id.source" ] \
    || fail "arm removed a registration that retire refused to remove ($dir)"
  printf '%s\n' "$elapsed" > "$dir/elapsed"
  rmdir "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" 2>/dev/null || true
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-procevent-lavish.sh" retire "$art" >/dev/null 2>&1 || true
}

arm_blocked_claim "$TMP_ROOT/immediate-arm" 1
pass "arm fails when the listener cannot claim, and leaves the registration retire refused"

arm_blocked_claim "$TMP_ROOT/timeout-arm" 2
tout_elapsed=$(cat "$TMP_ROOT/timeout-arm/elapsed")
[ "$tout_elapsed" -ge 2 ] \
  || fail "arm did not wait out the confirm window (${tout_elapsed}s)"
pass "arm waits out the confirm window before reporting that the listener is not running"

# Re-arming a firstmate-owned board publishes a new registration while the
# earlier generation's listener still holds the claim. When that listener still
# holds it as the confirm window ends, it keeps serving the board, so arm must
# say so instead of reporting failure, and must never claim this generation is
# the one listening.
LIVE="$TMP_ROOT/live-rearm"
mkdir -p "$LIVE/bin" "$LIVE/home/state"
cp "$READY/bin/lavish-axi" "$LIVE/bin/lavish-axi"
live_art="$LIVE/board.html"
printf '<h1>live</h1>\n' > "$live_art"
lavish_session "$live_art"
live_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$live_art")
fm_test_track_procevent_home "$LIVE/home"
export READY_MARK="$LIVE/mark" READY_RELEASE="$LIVE/release"
: > "$READY_MARK"
PATH="$LIVE/bin:$PATH" FM_HOME="$LIVE/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$live_art" > "$LIVE/arm1.out"
assert_contains "$(cat "$LIVE/arm1.out")" "armed: $live_id" "the first arm was not reported ready"
wait_for_lines "$READY_MARK" 1 || fail "the first generation's listener never ran"
set +e
PATH="$LIVE/bin:$PATH" FM_HOME="$LIVE/home" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$live_art" > "$LIVE/arm2.out" 2> "$LIVE/arm2.err"
live_rc=$?
set -e
[ "$live_rc" -eq 0 ] \
  || fail "re-arm over a live earlier listener failed ($live_rc): $(cat "$LIVE/arm2.err")"
assert_contains "$(cat "$LIVE/arm2.out")" "still-listening: $live_id" \
  "re-arm did not say the earlier listener is still serving the board"
assert_contains "$(cat "$LIVE/arm2.out")" "retired and armed again" \
  "re-arm did not say how the new registration takes effect"
assert_not_contains "$(cat "$LIVE/arm2.out")" "armed: $live_id" \
  "re-arm reported ready for a registration whose own listener is not running"
assert_not_contains "$(cat "$LIVE/arm2.err")" "error:" \
  "re-arm over a live earlier listener printed an error"
[ "$(pe "$LIVE/home" list | awk -v id="$live_id" '$1 == id { print $3 }')" = live ] \
  || fail "re-arm disturbed the live earlier listener"
sleep 0.3
[ "$(wc -l < "$READY_MARK" | tr -d ' ')" = 1 ] \
  || fail "re-arm started a second listener beside the live earlier one"
touch "$READY_RELEASE"
PATH="$LIVE/bin:$PATH" FM_HOME="$LIVE/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$live_art" >/dev/null 2>&1 || true
pass "re-arm over a live earlier listener reports it still serving the board"

# Old compatible Lavish versions keep using their existing poll reply path.
LEGACY="$TMP_ROOT/legacy-reply"
mkdir -p "$LEGACY/bin" "$LEGACY/home/state"
export LEGACY
cat > "$LEGACY/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  --version) printf '0.1.79\n' ;;
  poll)
    [ "${3-}" = --agent-reply ] || exit 3
    printf '%s\n' "$4" > "$LEGACY/reply"
    printf 'started\n' > "$LEGACY/started"
    while [ ! -e "$LEGACY/release" ]; do sleep 0.02; done
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","next round","","message",""\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$LEGACY/bin/lavish-axi"
legacy_art="$LEGACY/board.html"
printf '<h1>legacy reply</h1>\n' > "$legacy_art"
lavish_session "$legacy_art"
legacy_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$legacy_art")
fm_test_track_procevent_home "$LEGACY/home"
new_task_endpoint "$LEGACY/home" worker-legacy
printf 'legacy reply body\n' > "$LEGACY/reply-file"
PATH="$LEGACY/bin:$PATH" FM_HOME="$LEGACY/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$legacy_art" --for worker-legacy \
  --agent-reply-file "$LEGACY/reply-file" >/dev/null \
  || fail "the older compatible Lavish reply path did not arm"
wait_for "$LEGACY/reply" || fail "the older compatible poll never received its staged reply"
[ "$(cat "$LEGACY/reply")" = 'legacy reply body' ] \
  || fail "the legacy poll received different reply text"
touch "$LEGACY/release"
wait_for "$LEGACY/home/state/procevent-inbox/$legacy_id.1.result" \
  || fail "the legacy Lavish reply round was not captured"
pass "older compatible Lavish versions retain the poll-with-reply behavior"

# A failed synchronous reply must leave the worker board unarmed.
REPLY_FAIL="$TMP_ROOT/reply-fail"
mkdir -p "$REPLY_FAIL/bin" "$REPLY_FAIL/home/state"
export REPLY_FAIL
cat > "$REPLY_FAIL/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  reply) printf 'simulated reply timeout\n' >&2; exit 1 ;;
  poll) : > "$REPLY_FAIL/polled"; exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$REPLY_FAIL/bin/lavish-axi"
reply_fail_art="$REPLY_FAIL/board.html"
printf '<h1>reply failure</h1>\n' > "$reply_fail_art"
lavish_session "$reply_fail_art"
reply_fail_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$reply_fail_art")
fm_test_track_procevent_home "$REPLY_FAIL/home"
new_task_endpoint "$REPLY_FAIL/home" worker-reply-fail
printf 'reply that will fail\n' > "$REPLY_FAIL/reply-file"
reply_fail_rc=0
reply_fail_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" --for worker-reply-fail \
  --agent-reply-file "$REPLY_FAIL/reply-file" 2>&1) || reply_fail_rc=$?
[ "$reply_fail_rc" -ne 0 ] || fail "a refused reply let arm report success"
assert_contains "$reply_fail_out" 'Lavish did not accept the staged reply' \
  "a refused reply lacked a clear arm diagnostic: $reply_fail_out"
[ ! -e "$REPLY_FAIL/home/state/procevent/$reply_fail_id.source" ] \
  || fail "arm registered a board after Lavish refused its reply"
[ ! -e "$REPLY_FAIL/polled" ] || fail "arm started a listener after Lavish refused its reply"
pass "a refused synchronous reply fails arm before source registration"

cat > "$REPLY_FAIL/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  reply) printf '%s\n' "$(cat -- "$4")" >> "$REPLY_FAIL/replies" ;;
  poll) while [ ! -e "$REPLY_FAIL/release" ]; do sleep 0.02; done; exit 1 ;;
  *) exit 2 ;;
esac
SH
PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" --for worker-reply-fail \
  --agent-reply-file "$REPLY_FAIL/reply-file" >/dev/null \
  || fail "arm was not retryable with the same reply after Lavish refused it"
[ "$(cat "$REPLY_FAIL/replies")" = 'reply that will fail' ] \
  || fail "the retried arm did not post the worker's staged reply exactly once"
pass "a refused synchronous reply leaves the same arm retryable"

# An arm that fails ownership, pending-round, or endpoint eligibility must
# leave the board untouched: the reply is never posted.
: > "$REPLY_FAIL/replies"
printf 'foreign reply\n' > "$REPLY_FAIL/foreign-reply"
new_task_endpoint "$REPLY_FAIL/home" worker-intruder
refused_rc=0
refused_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" --for worker-intruder \
  --agent-reply-file "$REPLY_FAIL/foreign-reply" 2>&1) || refused_rc=$?
[ "$refused_rc" -ne 0 ] || fail "a non-owner arm with a reply was not refused"
assert_contains "$refused_out" "owned by task worker-reply-fail" \
  "the non-owner arm was refused for an unexpected reason: $refused_out"
refused_rc=0
refused_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" --for worker-reply-fail \
  --agent-reply-file "$REPLY_FAIL/foreign-reply" 2>&1) || refused_rc=$?
[ "$refused_rc" -ne 0 ] || fail "an owner re-arm with no waiting round was not refused"
assert_contains "$refused_out" "no captured round is waiting" \
  "the roundless re-arm was refused for an unexpected reason: $refused_out"
unreachable_art="$REPLY_FAIL/unreachable.html"
printf '<h1>unreachable owner</h1>\n' > "$unreachable_art"
lavish_session "$unreachable_art"
refused_rc=0
refused_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$unreachable_art" --for worker-no-endpoint \
  --agent-reply-file "$REPLY_FAIL/foreign-reply" 2>&1) || refused_rc=$?
[ "$refused_rc" -ne 0 ] || fail "an arm for a task with no endpoint was not refused"
assert_contains "$refused_out" "would reach no endpoint" \
  "the endpointless arm was refused for an unexpected reason: $refused_out"
[ ! -s "$REPLY_FAIL/replies" ] || fail "a refused arm posted its reply to the board: $(cat "$REPLY_FAIL/replies")"

reply_owner_claim="$FM_PROCEVENT_CLAIM_ROOT/$reply_fail_id.claim"
cp "$reply_owner_claim" "$REPLY_FAIL/owner.claim"
for foreign_scope in home state; do
  foreign_home="$REPLY_FAIL/foreign-$foreign_scope"
  new_home "$foreign_home"
  new_task_endpoint "$foreign_home" worker-intruder
  fm_test_track_procevent_home "$foreign_home"
  foreign_state="$foreign_home/state"
  [ "$foreign_scope" != state ] || foreign_home="$REPLY_FAIL/home"
  refused_rc=0
  refused_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$foreign_home" FM_STATE_OVERRIDE="$foreign_state" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" --for worker-intruder \
    --agent-reply-file "$REPLY_FAIL/foreign-reply" 2>&1) || refused_rc=$?
  [ "$refused_rc" -ne 0 ] || fail "a foreign $foreign_scope arm with a reply was not refused"
  assert_contains "$refused_out" "owned by home $REPLY_FAIL/home at state $REPLY_FAIL/home/state" \
    "the foreign $foreign_scope refusal did not name the retained claim's owner: $refused_out"
  [ ! -s "$REPLY_FAIL/replies" ] || fail "a foreign $foreign_scope arm posted its reply"
  [ ! -e "$foreign_state/procevent/$reply_fail_id.source" ] \
    || fail "a foreign $foreign_scope arm published a task registration"
  [ "$(cat "$REPLY_FAIL/foreign-reply")" = 'foreign reply' ] \
    || fail "a foreign $foreign_scope refusal consumed the original reply"
  cmp -s "$reply_owner_claim" "$REPLY_FAIL/owner.claim" \
    || fail "a foreign $foreign_scope arm changed the existing claim"

  refused_rc=0
  refused_out=$(PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$foreign_home" FM_STATE_OVERRIDE="$foreign_state" \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$reply_fail_art" 2>&1) || refused_rc=$?
  [ "$refused_rc" -ne 0 ] || fail "an ordinary arm accepted a foreign $foreign_scope listener as its predecessor"
  assert_not_contains "$refused_out" 'still-listening:' \
    "an ordinary arm reported a foreign $foreign_scope predecessor as its own"
  assert_not_contains "$refused_out" 'armed:' \
    "an ordinary arm reported a foreign $foreign_scope listener as ready"
  cmp -s "$reply_owner_claim" "$REPLY_FAIL/owner.claim" \
    || fail "an ordinary foreign $foreign_scope arm changed the existing claim"
  FM_HOME="$foreign_home" FM_STATE_OVERRIDE="$foreign_state" \
    "$ROOT/bin/fm-procevent.sh" retire "$reply_fail_id" >/dev/null \
    || fail "could not retire the foreign $foreign_scope registration"
done
pass "foreign homes and state roots neither post replies nor count another owner's live listener"

PATH="$REPLY_FAIL/bin:$PATH" FM_HOME="$REPLY_FAIL/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$reply_fail_art" >/dev/null 2>&1 || true
touch "$REPLY_FAIL/release"
pass "an arm refused for ownership, round, or endpoint never posts its reply"

# Direct poll callers use the same synchronous reply command on new Lavish builds.
POLL_REPLY="$TMP_ROOT/poll-reply"
mkdir -p "$POLL_REPLY/bin"
export POLL_REPLY
cat > "$POLL_REPLY/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  reply)
    [ "${3-}" = --agent-reply-file ] || exit 2
    [ "$(cat -- "$4")" = 'direct poll reply' ] || exit 3
    printf 'reply\n' >> "$POLL_REPLY/order"
    ;;
  poll)
    [ "$#" -eq 2 ] || exit 4
    printf 'poll\n' >> "$POLL_REPLY/order"
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","next round","","message",""\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$POLL_REPLY/bin/lavish-axi"
poll_reply_art="$POLL_REPLY/board.html"
printf '<h1>direct poll reply</h1>\n' > "$poll_reply_art"
lavish_session "$poll_reply_art"
printf 'direct poll reply\n' > "$POLL_REPLY/reply-file"
PATH="$POLL_REPLY/bin:$PATH" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$poll_reply_art" \
  --agent-reply-file "$POLL_REPLY/reply-file" >/dev/null \
  || fail "direct poll did not complete after synchronously posting its reply"
[ "$(cat "$POLL_REPLY/order")" = $'reply\npoll' ] \
  || fail "direct poll did not post the reply before entering the long-poll"
[ ! -e "$POLL_REPLY/reply-file" ] || fail "direct poll left its accepted staged reply behind"
pass "direct poll confirms a new-version reply before polling"

# An unreadable Lavish version is not a confirmed older release: arm and a
# reply-carrying listener fail closed without posting or falling back to poll.
UNKNOWN="$TMP_ROOT/unknown-version"
mkdir -p "$UNKNOWN/bin" "$UNKNOWN/home/state"
export UNKNOWN
cat > "$UNKNOWN/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) exit 1 ;;
  reply|poll) printf '%s\n' "$*" >> "$UNKNOWN/calls"; exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$UNKNOWN/bin/lavish-axi"
unknown_art="$UNKNOWN/board.html"
printf '<h1>unknown version</h1>\n' > "$unknown_art"
lavish_session "$unknown_art"
unknown_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$unknown_art")
fm_test_track_procevent_home "$UNKNOWN/home"
new_task_endpoint "$UNKNOWN/home" worker-unknown
printf 'reply for an unknown version\n' > "$UNKNOWN/reply-file"
unknown_rc=0
unknown_out=$(PATH="$UNKNOWN/bin:$PATH" FM_HOME="$UNKNOWN/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$unknown_art" --for worker-unknown \
  --agent-reply-file "$UNKNOWN/reply-file" 2>&1) || unknown_rc=$?
[ "$unknown_rc" -ne 0 ] || fail "arm fell back to a legacy reply when the Lavish version was unknown"
assert_contains "$unknown_out" 'cannot confirm a supported lavish-axi version' \
  "an unknown Lavish version lacked a clear arm diagnostic: $unknown_out"
[ ! -e "$UNKNOWN/home/state/procevent/$unknown_id.source" ] \
  || fail "arm registered a board while the Lavish version was unknown"
[ ! -e "$UNKNOWN/calls" ] || fail "arm reached the board with an unknown Lavish version: $(cat "$UNKNOWN/calls")"
[ "$(cat "$UNKNOWN/reply-file")" = 'reply for an unknown version' ] \
  || fail "arm consumed the worker's reply while the Lavish version was unknown"
cp "$UNKNOWN/reply-file" "$UNKNOWN/staged-reply"
unknown_rc=0
PATH="$UNKNOWN/bin:$PATH" "$ROOT/bin/fm-procevent-lavish.sh" poll "$unknown_art" \
  --agent-reply-file "$UNKNOWN/staged-reply" >/dev/null 2>&1 || unknown_rc=$?
[ "$unknown_rc" -ne 0 ] || fail "a reply-carrying poll proceeded with an unknown Lavish version"
[ ! -e "$UNKNOWN/calls" ] || fail "a reply-carrying poll reached the board with an unknown Lavish version: $(cat "$UNKNOWN/calls")"
[ "$(cat "$UNKNOWN/staged-reply")" = 'reply for an unknown version' ] \
  || fail "a reply-carrying poll consumed its staged reply with an unknown Lavish version"
pass "an unknown Lavish version fails arm and poll closed, keeping the staged reply"

# A worker re-arms as soon as its round is published, which can land while the
# earlier generation's runner is still finishing and holding the claim. The
# Lavish 0.1.80 stand-in records synchronous reply acceptance before its poll.
DRAIN="$TMP_ROOT/draining-rearm"
mkdir -p "$DRAIN/bin" "$DRAIN/home/state"
export DRAIN
cat > "$DRAIN/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  reply)
    [ "${3-}" = --agent-reply-file ] || exit 2
    printf '%s\n' "$(cat -- "$4")" >> "$DRAIN/replies"
    printf 'reply\n' >> "$DRAIN/order"
    ;;
  poll)
    printf 'poll\n' >> "$DRAIN/polls"
    printf 'poll\n' >> "$DRAIN/order"
    if [ "$(wc -l < "$DRAIN/polls")" -eq 1 ]; then
      while [ ! -e "$DRAIN/release1" ]; do sleep 0.02; done
    fi
    [ "${3-}" != --agent-reply ] || exit 3
    if [ "$(wc -l < "$DRAIN/polls")" -ge 2 ]; then
      while [ ! -e "$DRAIN/release2" ]; do sleep 0.02; done
    fi
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","next round","","message",""\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$DRAIN/bin/lavish-axi"
drain_art="$DRAIN/board.html"
printf '<h1>drain</h1>\n' > "$drain_art"
lavish_session "$drain_art"
drain_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$drain_art")
fm_test_track_procevent_home "$DRAIN/home"
new_task_endpoint "$DRAIN/home" worker-drain
printf 'first drain reply\n' > "$DRAIN/reply1"
printf 'second drain reply\n' > "$DRAIN/reply2"
PATH="$DRAIN/bin:$PATH" FM_HOME="$DRAIN/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$drain_art" --for worker-drain \
  --agent-reply-file "$DRAIN/reply1" >/dev/null \
  || fail "the first generation of the draining fixture did not arm"
[ "$(cat "$DRAIN/replies" 2>/dev/null || true)" = "first drain reply" ] \
  || fail "arm returned before Lavish accepted its staged reply"
[ "$(head -n 1 "$DRAIN/order")" = reply ] \
  || fail "arm started the long-poll before Lavish accepted the reply"
pass "arm posts and confirms the staged reply before reporting listener readiness"
drain_claim="$FM_PROCEVENT_CLAIM_ROOT/$drain_id.claim"
cp "$drain_claim" "$DRAIN/generation-one.claim"
touch "$DRAIN/release1"
wait_for "$DRAIN/home/state/procevent-inbox/$drain_id.1.result" \
  || fail "the first generation of the draining fixture never captured its round"
for _ in $(seq 1 100); do
  [ -e "$drain_claim" ] || break
  sleep 0.05
done
[ ! -e "$drain_claim" ] || fail "the first generation of the draining fixture never exited"
# Stand the first generation's claim back up on a live process so the re-arm
# meets it still held, then release it partway through the confirm window.
setsid sleep 60 &
drain_holder=$!
# Read the identity only once the holder has exec'd sleep: mid-exec its cmdline
# can read empty, and a pre-exec identity would never match the live holder.
for _ in $(seq 1 100); do
  case "$(ps -p "$drain_holder" -o comm= 2>/dev/null)" in *sleep) break ;; esac
  sleep 0.05
done
drain_holder_identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$drain_holder") \
  || fail "could not read the draining holder's identity"
awk -v pid="$drain_holder" -v ident="$drain_holder_identity" \
  'NR == 2 { print pid; next } NR == 4 { print ident; next } { print }' \
  "$DRAIN/generation-one.claim" > "$drain_claim"
chmod 0600 "$drain_claim"
[ "$(pe "$DRAIN/home" list | awk -v id="$drain_id" '$1 == id { print $3 }')" = task:worker-drain/round-open ] \
  || fail "fixture invalid: the stood-up first generation is not reported live: $(pe "$DRAIN/home" list)"
PATH="$DRAIN/bin:$PATH" FM_HOME="$DRAIN/home" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=5 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$drain_art" --for worker-drain \
  --agent-reply-file "$DRAIN/reply2" > "$DRAIN/arm2.out" 2> "$DRAIN/arm2.err" &
drain_arm=$!
sleep 1
kill -KILL "$drain_holder" 2>/dev/null || true
wait "$drain_holder" 2>/dev/null || true
wait "$drain_arm" \
  || fail "re-arm failed after the earlier claim was released: $(cat "$DRAIN/arm2.err")"
assert_contains "$(cat "$DRAIN/arm2.out")" "armed: $drain_id" \
  "re-arm did not launch the new generation once the earlier claim was released"
assert_not_contains "$(cat "$DRAIN/arm2.out")" "still-listening" \
  "re-arm reported the released earlier listener as still serving the board"
wait_for_lines "$DRAIN/replies" 2 \
  || fail "the new generation never handed the board the worker's reply"
[ "$(grep -c 'second drain reply' "$DRAIN/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the new generation did not hand the board its own reply exactly once"
touch "$DRAIN/release2"
wait_for "$DRAIN/home/state/procevent-inbox/$drain_id.2.result" \
  || fail "the new generation never captured its round"
pass "re-arm launches the new generation once a draining earlier claim is released"

# A stale claim whose process group is still alive may still have its polling
# child on the board's session. Reconcile refuses to launch beside it, and arm
# must apply the same rule instead of adding a second destructive poller.
UNDISP="$TMP_ROOT/undisplaceable-arm"
mkdir -p "$UNDISP/bin" "$UNDISP/home/state"
cp "$READY/bin/lavish-axi" "$UNDISP/bin/lavish-axi"
undisp_art="$UNDISP/board.html"
printf '<h1>undisplaceable</h1>\n' > "$undisp_art"
lavish_session "$undisp_art"
undisp_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$undisp_art")
fm_test_track_procevent_home "$UNDISP/home"
export READY_MARK="$UNDISP/mark" READY_RELEASE="$UNDISP/release"
: > "$READY_MARK"
PATH="$UNDISP/bin:$PATH" FM_HOME="$UNDISP/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$undisp_art" >/dev/null
wait_for_lines "$READY_MARK" 1 || fail "the undisplaceable fixture's listener never ran"
undisp_claim="$FM_PROCEVENT_CLAIM_ROOT/$undisp_id.claim"
undisp_identity=$(sed -n '4p' "$undisp_claim")
awk 'NR == 4 { print "different-live-process-identity"; next } { print }' \
  "$undisp_claim" > "$undisp_claim.tmp" && mv "$undisp_claim.tmp" "$undisp_claim"
chmod 0600 "$undisp_claim"
[ "$(pe "$UNDISP/home" list | awk -v id="$undisp_id" '$1 == id { print $3 }')" = orphaned ] \
  || fail "fixture invalid: the reused-pid claim is not reported orphaned"
set +e
PATH="$UNDISP/bin:$PATH" FM_HOME="$UNDISP/home" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$undisp_art" > "$UNDISP/arm2.out" 2>/dev/null
undisp_rc=$?
set -e
sleep 0.5
[ "$(wc -l < "$READY_MARK" | tr -d ' ')" = 1 ] \
  || fail "arm started a second listener beside a stale claim's live process group"
[ "$undisp_rc" -ne 0 ] || fail "arm reported success beside an undisplaceable claim"
assert_not_contains "$(cat "$UNDISP/arm2.out")" "armed: $undisp_id" \
  "arm reported ready beside an undisplaceable claim"
[ -e "$UNDISP/home/state/procevent/$undisp_id.source" ] \
  || fail "arm retired a source whose earlier listener may still be polling"
awk -v v="$undisp_identity" 'NR == 4 { print v; next } { print }' \
  "$undisp_claim" > "$undisp_claim.tmp" && mv "$undisp_claim.tmp" "$undisp_claim"
chmod 0600 "$undisp_claim"
touch "$READY_RELEASE"
PATH="$UNDISP/bin:$PATH" FM_HOME="$UNDISP/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$undisp_art" >/dev/null 2>&1 || true
pass "arm does not launch beside a stale claim whose process group is alive"

printf '\nall procevent tests passed\n'
