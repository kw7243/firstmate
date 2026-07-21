#!/usr/bin/env bash
# Behavior tests for the per-home firstmate session lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
LOCK="$ROOT/bin/fm-lock.sh"

make_hidden_harness_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_codex_sandbox_identity_acquires_without_visible_parent() {
  local dir home fakebin out status
  dir="$TMP_ROOT/codex-acquire"
  home="$dir/home"
  mkdir -p "$home/state"
  fakebin=$(make_hidden_harness_fakebin "$dir/fake")

  status=0
  out=$(FM_HOME="$home" CODEX_THREAD_ID=thread-123 CODEX_SANDBOX_NETWORK_DISABLED=1 \
    PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "codex sandbox owner should acquire the lock"
  assert_contains "$out" "lock acquired: sandbox codex session" "sandbox lock acquisition output was unclear"
  [ "$(cat "$home/state/.lock")" = "codex-thread:thread-123" ] \
    || fail "sandbox lock did not record the codex thread owner"
  pass "codex sandbox identity acquires the session lock without visible parent pid"
}

test_same_codex_sandbox_identity_reacquires() {
  local dir home fakebin out status
  dir="$TMP_ROOT/codex-reacquire"
  home="$dir/home"
  mkdir -p "$home/state"
  printf '%s\n' "codex-thread:thread-abc" > "$home/state/.lock"
  fakebin=$(make_hidden_harness_fakebin "$dir/fake")

  status=0
  out=$(FM_HOME="$home" CODEX_THREAD_ID=thread-abc CODEX_SANDBOX_NETWORK_DISABLED=1 \
    PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "same codex sandbox owner should reacquire the lock"
  assert_contains "$out" "lock acquired: sandbox codex session" "same sandbox owner did not reacquire cleanly"
  pass "same codex sandbox identity can refresh the session lock"
}

test_foreign_codex_sandbox_identity_fails_closed() {
  local dir home fakebin out status
  dir="$TMP_ROOT/codex-foreign"
  home="$dir/home"
  mkdir -p "$home/state"
  printf '%s\n' "codex-thread:other-thread" > "$home/state/.lock"
  fakebin=$(make_hidden_harness_fakebin "$dir/fake")

  status=0
  out=$(FM_HOME="$home" CODEX_THREAD_ID=this-thread CODEX_SANDBOX_NETWORK_DISABLED=1 \
    PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || status=$?

  expect_code 1 "$status" "foreign opaque owner must block acquisition"
  assert_contains "$out" "another live or unverifiable firstmate session holds the lock" \
    "foreign opaque owner did not fail closed"
  [ "$(cat "$home/state/.lock")" = "codex-thread:other-thread" ] \
    || fail "foreign opaque owner was overwritten"
  pass "foreign codex sandbox identity fails closed"
}

test_status_reports_current_sandbox_owner() {
  local dir home fakebin out
  dir="$TMP_ROOT/codex-status"
  home="$dir/home"
  mkdir -p "$home/state"
  printf '%s\n' "codex-thread:status-thread" > "$home/state/.lock"
  fakebin=$(make_hidden_harness_fakebin "$dir/fake")

  out=$(FM_HOME="$home" CODEX_THREAD_ID=status-thread CODEX_SANDBOX_NETWORK_DISABLED=1 \
    PATH="$fakebin:$BASE_PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by this sandboxed codex session" \
    "status did not recognize the current sandbox owner"
  pass "status recognizes the current sandboxed codex owner"
}

test_codex_sandbox_identity_acquires_without_visible_parent
test_same_codex_sandbox_identity_reacquires
test_foreign_codex_sandbox_identity_fails_closed
test_status_reports_current_sandbox_owner
