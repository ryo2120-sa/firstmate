#!/usr/bin/env bash
# Transient live driver (removed after the run): a stale / partially restored
# Herdr adapter reaching the real fm-teardown.sh CLI.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/.fm-td-helpers.sh"

build_tree() {  # <dest> <drop-prerequisite-registration:0|1>
  local dest=$1 drop=$2
  rm -rf "$dest"; mkdir -p "$dest"
  cp -R "$ROOT/bin" "$dest/bin"
  sed -i.bak 's/^fm_backend_herdr_presentation_lock_wait_attempts()/fm_backend_herdr_presentation_lock_wait_attempts_unavailable()/' \
    "$dest/bin/backends/herdr.sh"
  rm -f "$dest/bin/backends/herdr.sh.bak"
  if [ "$drop" = 1 ]; then
    sed -i.bak \
      -e '/^    fm_backend_herdr_presentation_lock_wait_attempts; do$/d' \
      -e 's|^    fm_backend_herdr_presentation_session_lock_path \\$|    fm_backend_herdr_presentation_session_lock_path; do|' \
      "$dest/bin/fm-teardown.sh"
    rm -f "$dest/bin/fm-teardown.sh.bak"
  fi
  bash -n "$dest/bin/fm-teardown.sh" || { echo "DRIVER ERROR: mangled tree"; exit 90; }
}

drive() {  # <label> <drop>
  local label=$1 drop=$2 case_dir log closed rc tree
  case_dir=$(make_case "stale-$label")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"; closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"; : > "$case_dir/state/task-x1.turn-ended"
  tree="$case_dir/test-root"
  build_tree "$tree" "$drop"
  printf '  prerequisite list:\n'
  sed -n '/^teardown_herdr_require_prerequisites()/,/; do$/p' "$tree/bin/fm-teardown.sh" \
    | sed 's/^/    /'
  rc=0
  FM_ROOT_OVERRIDE="$tree" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    PATH="$case_dir/fakebin:$PATH" \
    "$tree/bin/fm-teardown.sh" task-x1 --force \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  printf '  %s: exit=%s\n  stderr: %s\n' "$label" "$rc" "$(tr '\n' '|' < "$case_dir/stderr")"
  printf '  pane closed=%s  metadata kept=%s\n' \
    "$([ -e "$closed" ] && echo yes || echo no)" \
    "$([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
}

echo "=== A: stale adapter WITH this change's prerequisite registration ==="
drive with-registration 0
echo
echo "=== B: same stale adapter WITHOUT the prerequisite registration (counterfactual) ==="
drive without-registration 1
