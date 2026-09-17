#!/usr/bin/env bash
# End-to-end driver for the Pi Claude-provider idle-timeout pin.
#
# Runs the real bin/fm-spawn.sh CLI against an isolated FM_HOME and a real git
# worktree, with a tmux shim that behaves like real tmux AND actually runs the
# `send-keys -l` payload the way a real pane's shell would. The harness binary
# on PATH is a recorder that prints the environment the launched worker process
# actually received; its `--help` probe is delegated to the REAL installed pi so
# fm-spawn's version probing is authentic.
set -u

ROOT=${FM_SPAWN_ROOT:?set FM_SPAWN_ROOT to the worktree}
REAL_PI=${REAL_PI:-/Users/nguyenl8/.npm-global/bin/pi}
RUN_ROOT=${RUN_ROOT:?set RUN_ROOT}
rm -rf "$RUN_ROOT"; mkdir -p "$RUN_ROOT"

FAILURES=0
say() { printf '%s\n' "$*"; }

make_shims() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        printf '%s\n' "$a" >> "$FM_PANE_LAUNCH_LOG"
        # A real tmux pane's shell runs what was typed. Reproduce that, with the
        # pane inheriting the ambient (server-side) idle-timeout value.
        if [ "${FM_PANE_AMBIENT_IDLE:-unset}" = unset ]; then
          ( cd "${FM_FAKE_PANE_PATH:-/}" && env -u PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS \
              FM_WORKER_ENV_LOG="$FM_WORKER_ENV_LOG" PATH="$FM_SHIM_BIN:$PATH" \
              bash -c "$a" ) >> "$FM_PANE_RUN_LOG" 2>&1
        else
          ( cd "${FM_FAKE_PANE_PATH:-/}" && env PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS="$FM_PANE_AMBIENT_IDLE" \
              FM_WORKER_ENV_LOG="$FM_WORKER_ENV_LOG" PATH="$FM_SHIM_BIN:$PATH" \
              bash -c "$a" ) >> "$FM_PANE_RUN_LOG" 2>&1
        fi
        printf 'pane-shell-exit=%s\n' "$?" >> "$FM_PANE_RUN_LOG"
      fi
      prev=$a
    done
    exit 0 ;;
esac
exit 0
SH
  # Harness recorders. `pi`/`pi-signed` delegate --help to the real installed pi
  # so fm-spawn's --tui-mode capability probe is a real probe.
  for tool in pi pi-signed; do
    cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = --help ]; then exec "$REAL_PI" --help; fi
{
  printf 'launched-binary: %s\n' "\$0"
  printf 'FM_PI_HARNESS=%s\n' "\${FM_PI_HARNESS-<unset>}"
  printf 'PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=%s\n' "\${PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS-<unset>}"
} > "\$FM_WORKER_ENV_LOG"
exit 0
SH
  done
  for tool in claude codex omp cursor-agent; do
    cat > "$bin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ] || [ "${1:-}" = models ] || [ "${1:-}" = --list-models ]; then exit 0; fi
{
  printf 'launched-binary: %s\n' "$0"
  printf 'PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=%s\n' "${PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS-<unset>}"
} > "$FM_WORKER_ENV_LOG"
exit 0
SH
  done
  cat > "$bin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin"/*
}

# new_case <name> <crew-harness>
new_case() {
  local name=$1 harness=$2 case_dir
  case_dir="$RUN_ROOT/$name"
  mkdir -p "$case_dir"/{home/data,home/state,home/config,home/projects,home/user-home,project}
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' "$harness" > "$case_dir/home/config/crew-harness"
  make_shims "$case_dir/bin"
  ( cd "$case_dir/project" && git init -q . && git config user.email t@e.st && git config user.name t \
      && printf 'demo\n' > README.md && git add -A && git commit -qm init \
      && git worktree add -q -b "wt-$name" "$case_dir/wt" >/dev/null 2>&1 )
  printf '%s\n' "$case_dir"
}

seed_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Keep the Portfolio Desk worker alive through long quiet stretches.

## Firstmate spec
Exercise the Pi launch idle-timeout pin.
EOF
}

# drive <case-dir> <task-id> <ambient-idle|unset> <spawn args...>
drive() {
  local case_dir=$1 id=$2 ambient=$3
  shift 3
  local home="$case_dir/home" bin="$case_dir/bin"
  : > "$case_dir/launch.log"; : > "$case_dir/pane.log"; : > "$case_dir/worker-env.log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX='fake,1,0' \
    FM_PANE_LAUNCH_LOG="$case_dir/launch.log" FM_PANE_RUN_LOG="$case_dir/pane.log" \
    FM_WORKER_ENV_LOG="$case_dir/worker-env.log" FM_SHIM_BIN="$bin" \
    FM_PANE_AMBIENT_IDLE="$ambient" \
    PATH="$bin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

check_worker_idle() {
  local case_dir=$1 want=$2 label=$3 actual
  actual=$(grep '^PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=' "$case_dir/worker-env.log" 2>/dev/null | cut -d= -f2-)
  if [ "$actual" = "$want" ]; then
    say "PASS  $label -> worker process saw PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=$actual"
  else
    say "FAIL  $label -> expected $want, worker process saw '${actual:-<no worker launched>}'"
    FAILURES=$((FAILURES + 1))
  fi
}

banner() { printf '\n=== %s ===\n' "$*"; }

# --- S1: captain spawns a Pi crewmate while an ambient 5-minute value is set ---
banner "S1 pi crewmate (ambient PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=300000)"
cd1=$(new_case s1-pi pi); id=pd-desk-001; seed_brief "$cd1/home" "$id"
drive "$cd1" "$id" 300000 "$id" "$cd1/project" --mode no-mistakes --yolo off --harness pi
say "--- launch command sent to the pane ---"; cat "$cd1/launch.log"
say "--- environment observed by the launched worker process ---"; cat "$cd1/worker-env.log"
check_worker_idle "$cd1" 1800000 "S1 pi crewmate"

# --- S2: pi-signed crewmate ---
banner "S2 pi-signed crewmate (ambient 300000)"
cd2=$(new_case s2-pi-signed pi-signed); id=pd-desk-002; seed_brief "$cd2/home" "$id"
drive "$cd2" "$id" 300000 "$id" "$cd2/project" --mode no-mistakes --yolo off --harness pi-signed
say "--- environment observed by the launched worker process ---"; cat "$cd2/worker-env.log"
check_worker_idle "$cd2" 1800000 "S2 pi-signed crewmate"

# --- S3: persistent Pi secondmate ---
banner "S3 persistent pi secondmate (ambient 300000)"
cd3=$(new_case s3-secondmate pi); id=pd-desk-003; seed_brief "$cd3/home" "$id"
printf 'pi\n' > "$cd3/home/config/secondmate-harness"
sm="$cd3/secondmate-home"; mkdir -p "$sm/bin" "$sm/data"
printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
sm=$(cd "$sm" && pwd -P)
drive "$cd3" "$id" 300000 "$id" "$sm" --secondmate
say "--- environment observed by the launched secondmate process ---"; cat "$cd3/worker-env.log"
check_worker_idle "$cd3" 1800000 "S3 pi secondmate"

# --- S4: raw launch escape hatch (skips launch_template) ---
banner "S4 raw Pi launch escape hatch (ambient 300000)"
cd4=$(new_case s4-raw pi); id=pd-desk-004; seed_brief "$cd4/home" "$id"
drive "$cd4" "$id" 300000 "$id" "$cd4/project" 'pi --tui-mode regular' --mode no-mistakes --yolo off
say "--- launch command sent to the pane ---"; cat "$cd4/launch.log"
say "--- environment observed by the launched worker process ---"; cat "$cd4/worker-env.log"
check_worker_idle "$cd4" 1800000 "S4 raw pi launch"

# --- S5 adversarial: ambient value HIGHER than the pin ---
banner "S5 adversarial: ambient 3600000 must not win over the pinned 1800000"
cd5=$(new_case s5-high pi); id=pd-desk-005; seed_brief "$cd5/home" "$id"
drive "$cd5" "$id" 3600000 "$id" "$cd5/project" --mode no-mistakes --yolo off --harness pi
say "--- environment observed by the launched worker process ---"; cat "$cd5/worker-env.log"
check_worker_idle "$cd5" 1800000 "S5 ambient-higher pi crewmate"

# --- S6: no ambient value at all ---
banner "S6 no ambient value set anywhere"
cd6=$(new_case s6-unset pi); id=pd-desk-006; seed_brief "$cd6/home" "$id"
drive "$cd6" "$id" unset "$id" "$cd6/project" --mode no-mistakes --yolo off --harness pi
say "--- environment observed by the launched worker process ---"; cat "$cd6/worker-env.log"
check_worker_idle "$cd6" 1800000 "S6 clean-environment pi crewmate"

# --- S7 adversarial: a non-Pi harness must not pick the pin up ---
banner "S7 claude crewmate must not receive the Pi pin"
cd7=$(new_case s7-claude claude); id=pd-desk-007; seed_brief "$cd7/home" "$id"
drive "$cd7" "$id" unset "$id" "$cd7/project" --mode no-mistakes --yolo off --harness claude
say "--- environment observed by the launched worker process ---"; cat "$cd7/worker-env.log"
check_worker_idle "$cd7" '<unset>' "S7 claude crewmate (no Pi pin)"

# --- S8: omp stays explicitly out of scope ---
banner "S8 omp crewmate stays out of scope (no Pi pin)"
cd8=$(new_case s8-omp omp); id=pd-desk-008; seed_brief "$cd8/home" "$id"
drive "$cd8" "$id" unset "$id" "$cd8/project" --mode no-mistakes --yolo off --harness omp
say "--- environment observed by the launched worker process ---"; cat "$cd8/worker-env.log"
check_worker_idle "$cd8" '<unset>' "S8 omp crewmate (out of scope)"

banner "RESULT"
if [ "$FAILURES" -eq 0 ]; then say "all driven scenarios passed"; else say "$FAILURES scenario(s) failed"; fi
exit "$FAILURES"
