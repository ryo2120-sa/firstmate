#!/usr/bin/env bash
# S9: drive `fm-spawn.sh <id> --relaunch` for an existing Pi task and observe the
# environment the REPLACEMENT worker process actually receives.
#
# --relaunch refuses unless the recorded endpoint is positively agent-free. The
# tmux shim therefore reports the endpoint the way real tmux reports a pane whose
# agent has exited and is back at its shell: the recorded window is present in the
# session inventory and its current command is `bash`. bin/backends/tmux.sh then
# classifies the endpoint `dead`, which is the state a captain relaunches from.
set -u
ROOT=${FM_SPAWN_ROOT:?}
CASE=${CASE_DIR:?}

cat > "$CASE/bin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) printf '%s\n' "${FM_FAKE_WINDOW:-}"; exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option|respawn-window) exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        printf '%s\n' "$a" >> "$FM_PANE_LAUNCH_LOG"
        ( cd "${FM_FAKE_PANE_PATH:-/}" && env PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS="$FM_PANE_AMBIENT_IDLE" \
            FM_WORKER_ENV_LOG="$FM_WORKER_ENV_LOG" PATH="$FM_SHIM_BIN:$PATH" bash -c "$a" ) >> "$FM_PANE_RUN_LOG" 2>&1
        printf 'pane-shell-exit=%s\n' "$?" >> "$FM_PANE_RUN_LOG"
      fi
      prev=$a
    done
    exit 0 ;;
esac
exit 0
SH
chmod +x "$CASE/bin/tmux"

home="$CASE/home"
id=$(grep -m1 '^endpoint_task_id=' "$home"/state/*.meta | cut -d= -f2)
window=$(grep -m1 '^window=' "$home/state/$id.meta" | cut -d= -f2)
: > "$CASE/launch.log"; : > "$CASE/worker-env.log"; : > "$CASE/pane.log"
printf -- '--- recorded task before relaunch ---\n'
grep -E '^(window|harness|kind|worktree)=' "$home/state/$id.meta"
printf -- '\n--- captain relaunches Pi task %s into endpoint %s (pane ambient value 300000) ---\n' "$id" "$window"
FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_FAKE_PANE_PATH="$CASE/wt" TMUX='fake,1,0' \
  FM_FAKE_WINDOW="${window#*:}" \
  FM_PANE_LAUNCH_LOG="$CASE/launch.log" FM_PANE_RUN_LOG="$CASE/pane.log" \
  FM_WORKER_ENV_LOG="$CASE/worker-env.log" FM_SHIM_BIN="$CASE/bin" \
  FM_PANE_AMBIENT_IDLE=300000 PATH="$CASE/bin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1
printf 'fm-spawn exit=%s\n' "$?"
printf -- '--- launch command sent to the pane ---\n'; cat "$CASE/launch.log"
printf -- '--- environment observed by the replacement worker process ---\n'; cat "$CASE/worker-env.log"
actual=$(grep '^PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=' "$CASE/worker-env.log" 2>/dev/null | cut -d= -f2-)
if [ "$actual" = 1800000 ]; then
  printf 'PASS  S9 pi relaunch -> replacement worker saw PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=%s\n' "$actual"; exit 0
fi
printf 'FAIL  S9 pi relaunch -> expected 1800000, saw %s\n' "${actual:-<no worker launched>}"; exit 1
