#!/usr/bin/env bash
# Behavior tests for primary harness detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HARNESS="$ROOT/bin/fm-harness.sh"

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

test_codex_thread_marker_detects_codex_without_process_ancestry() {
  local fakebin out
  fakebin=$(make_hidden_harness_fakebin "$TMP_ROOT/codex-marker")

  out=$(CODEX_THREAD_ID=thread-123 PATH="$fakebin:$BASE_PATH" "$HARNESS")

  [ "$out" = codex ] || fail "CODEX_THREAD_ID should detect codex, got: $out"
  pass "CODEX_THREAD_ID detects codex when process ancestry is hidden"
}

test_codex_thread_marker_detects_codex_without_process_ancestry
