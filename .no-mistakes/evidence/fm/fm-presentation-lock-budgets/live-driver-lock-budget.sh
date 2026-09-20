#!/usr/bin/env bash
# Transient live driver (NOT a repo test - removed after the run).
# Drives the real bin/fm-teardown.sh CLI and the real fm_backend_kill
# dispatcher against a REAL on-disk presentation lock held by a REAL peer
# process, with REAL wall-clock sleeps. DRIVE_ROOT selects which code tree
# is driven, so the same scenarios can be run against pre-fix and post-fix code.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/.fm-td-helpers.sh"

DRIVE_ROOT=${DRIVE_ROOT:-$ROOT}
FIXTURE_ROOT=$ROOT          # fixtures/lock-path resolution always use the driven tree
ROOT=$DRIVE_ROOT
TEARDOWN="$ROOT/bin/fm-teardown.sh"
printf 'DRIVING CODE TREE: %s\n' "$ROOT"

hold_lock() {  # <lock> <ready> <release>
  ROOT="$ROOT" LOCK=$1 READY=$2 RELEASE=$3 bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.05; done
    fm_lock_release "$LOCK"
  ' &
  HOLDER_PID=$!
  local waited=0
  while [ ! -e "$2" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$2" ] || { echo "DRIVER ERROR: peer holder never started"; exit 90; }
}

release_after() {  # <seconds> <release>
  ( sleep "$1"; : > "$2" ) &
}

resolve_lock() {  # <case_dir>
  PATH="$1/fakebin:$PATH" bash -c \
    '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT"
}

# ---------------------------------------------------------------------------
# S1 / S2: real `fm-teardown.sh` while a peer holds the lock for HOLD seconds.
# ---------------------------------------------------------------------------
drive_teardown() {  # <label> <hold-seconds> <env-override-or-empty>
  local label=$1 hold=$2 override=$3
  local case_dir log closed lock ready release thlog rc start elapsed
  case_dir=$(make_case "drive-$label")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" resolve_lock "$case_dir") \
    || { echo "DRIVER ERROR: no lock path"; exit 91; }
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  hold_lock "$lock" "$ready" "$release"
  release_after "$hold" "$release"

  echo "--- $label: peer holds $lock for ${hold}s; running real fm-teardown.sh ---"
  rc=0
  start=$(date +%s)
  if [ -n "$override" ]; then
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
      FM_BACKEND_HERDR_PRESENTATION_LOCK_WAIT_ATTEMPTS="$override" \
      FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
      run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  else
    unset FM_BACKEND_HERDR_PRESENTATION_LOCK_WAIT_ATTEMPTS
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
      FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
      run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  : > "$release"; wait "$HOLDER_PID" 2>/dev/null || true

  printf 'exit=%s elapsed=%ss\n' "$rc" "$elapsed"
  printf 'stdout: %s\n' "$(tr '\n' '|' < "$case_dir/stdout")"
  printf 'stderr: %s\n' "$(tr '\n' '|' < "$case_dir/stderr")"
  if grep -q "presentation lock is contended" "$case_dir/stderr"; then
    printf 'RESULT %s: REFUSED (contended) after %ss; pane closed=%s; worktree returned=%s\n' \
      "$label" "$elapsed" "$([ -e "$closed" ] && echo yes || echo no)" "$([ -s "$thlog" ] && echo yes || echo no)"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'RESULT %s: FAILED exit=%s after %ss\n' "$label" "$rc" "$elapsed"
    return 2
  fi
  [ -e "$closed" ] || { printf 'RESULT %s: completed but never closed the pane\n' "$label"; return 3; }
  [ -s "$thlog" ] || { printf 'RESULT %s: completed but never returned the isolated copy\n' "$label"; return 4; }
  [ ! -e "$case_dir/state/task-x1.meta" ] || { printf 'RESULT %s: metadata left behind\n' "$label"; return 5; }
  grep -q "teardown task-x1 complete" "$case_dir/stdout" \
    || { printf 'RESULT %s: no completion line\n' "$label"; return 6; }
  printf 'RESULT %s: COMPLETED after %ss (pane closed, isolated copy returned, metadata removed)\n' "$label" "$elapsed"
  return 0
}

# ---------------------------------------------------------------------------
# S3: real fm_backend_kill dispatcher while a peer holds the same lock.
# ---------------------------------------------------------------------------
drive_kill() {  # <label> <hold-seconds>
  local label=$1 hold=$2
  local case_dir log closed lock ready release out start elapsed
  case_dir=$(make_case "drive-$label")
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" resolve_lock "$case_dir") \
    || { echo "DRIVER ERROR: no lock path"; exit 91; }
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  hold_lock "$lock" "$ready" "$release"
  release_after "$hold" "$release"

  echo "--- $label: peer holds $lock for ${hold}s; running real fm_backend_kill herdr ---"
  start=$(date +%s)
  out=$(unset FM_BACKEND_HERDR_PRESENTATION_LOCK_WAIT_ATTEMPTS
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_kill herdr default:wG:pQ' "$ROOT" 2>&1)
  elapsed=$(( $(date +%s) - start ))
  : > "$release"; wait "$HOLDER_PID" 2>/dev/null || true
  printf 'elapsed=%ss output: %s\n' "$elapsed" "${out:-<none>}"
  printf 'herdr calls: %s\n' "$(tr '\n' '|' < "$log")"
  case "$out" in
    *"refusing an unlocked pane close"*)
      printf 'RESULT %s: REFUSED the pane close after %ss (pane left alive)\n' "$label" "$elapsed"
      return 1 ;;
  esac
  [ -e "$closed" ] || { printf 'RESULT %s: no refusal but the pane was never closed\n' "$label"; return 2; }
  printf 'RESULT %s: CLOSED the pane after %ss\n' "$label" "$elapsed"
  return 0
}

STATUS=0
case "${DRIVE_CASE:?set DRIVE_CASE}" in
  teardown-peer-hold)   drive_teardown teardown-peer-hold "${HOLD:-6.5}" "" || STATUS=$? ;;
  teardown-zero-override) drive_teardown teardown-zero-override "${HOLD:-20}" 0 || STATUS=$? ;;
  teardown-garbage-override) drive_teardown teardown-garbage-override "${HOLD:-20}" abc || STATUS=$? ;;
  kill-peer-hold)       drive_kill kill-peer-hold "${HOLD:-6.5}" || STATUS=$? ;;
  teardown-small-override) drive_teardown teardown-small-override "${HOLD:-20}" 3 || STATUS=$? ;;
esac
echo "DRIVER EXIT=$STATUS"
exit "$STATUS"
