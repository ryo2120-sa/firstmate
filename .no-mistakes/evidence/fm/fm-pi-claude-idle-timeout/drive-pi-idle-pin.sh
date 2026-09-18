#!/usr/bin/env bash
# Live drive: spawn Pi workers through the REAL bin/fm-spawn.sh and the REAL
# Herdr terminal backend (isolated lab session), and read the idle-timeout value
# out of the launched harness process's own environment.
set -u

ROOT=${ROOT_UNDER_TEST:-/Users/nguyenl8/.no-mistakes/worktrees/8642b6d0ddaf/01M2T5NSM0SHZPW990FP5WBYGW}
EV=/Users/nguyenl8/.no-mistakes/evidence/01M2T5NSM0SHZPW990FP5WBYGW

# Ambient hostile value: exported BEFORE the lab herdr server is provisioned so
# the server, and therefore every pane it creates, inherits it. FM_AMBIENT_PROBE
# is the control that proves the ambient environment really reached the pane.
export PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS="${AMBIENT:-300000}"
export FM_AMBIENT_PROBE="${AMBIENT:-300000}"

command -v herdr >/dev/null || { echo "fatal: herdr missing"; exit 1; }
command -v jq >/dev/null || { echo "fatal: jq missing"; exit 1; }
command -v treehouse >/dev/null || { echo "fatal: treehouse missing"; exit 1; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-idle-live.XXXXXX")
ENVLOG="$TMP_ROOT/harness-env.log"
: > "$ENVLOG"
FAKEBIN="$TMP_ROOT/bin"; mkdir -p "$FAKEBIN"

LAB="$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESSION=$("$LAB" name fm-pi-idle) || { echo "fatal: lab name"; exit 1; }
export HERDR_SESSION="$SESSION"
export FM_GATE_REFUSE_BYPASS=1

WORKTREES=()
CLEANED=0
cleanup() {
  local wt
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  pkill -f "$TMP_ROOT/bin/" 2>/dev/null || true
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    case "$wt" in
      "$HOME"/.treehouse/scratch-project-*/*) rm -rf "$(dirname "$(dirname "$wt")")" ;;
    esac
  done
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || echo "warn: lab teardown reported a problem"
}
trap cleanup EXIT

# --- stand-in harness executables ------------------------------------------
# Stand in for the real Pi/omp CLI (a real Pi session would start an autonomous
# agent against a live provider). Each records the environment it was ACTUALLY
# launched with, then idles so the pane stays alive like a real harness.
make_stub() { # <name>
  cat > "$FAKEBIN/$1" <<STUB
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = --help ]; then
  printf '%s\n' 'Pi ${FM_STUB_VERSION:-0.84.0}' 'Options: --help --tui-mode <mode>'
  exit 0
fi
{
  printf '=== launched %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'argv0=%s\n' "\$0"
  printf 'cwd=%s\n' "\$PWD"
  printf 'FM_PI_HARNESS=%s\n' "\${FM_PI_HARNESS-<unset>}"
  printf 'FM_OMP_HARNESS=%s\n' "\${FM_OMP_HARNESS-<unset>}"
  printf 'PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=%s\n' "\${PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS-<unset>}"
  printf 'FM_AMBIENT_PROBE=%s\n' "\${FM_AMBIENT_PROBE-<unset>}"
} >> "$ENVLOG"
exec sleep 900
STUB
  chmod +x "$FAKEBIN/$1"
}
make_stub pi
make_stub pi-signed
make_stub omp

# --- scratch world ----------------------------------------------------------
PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Idle Pin Live' -c user.email='live@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

FM_HOME_DIR="$TMP_ROOT/fm-home"
mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/config" "$FM_HOME_DIR/data" "$FM_HOME_DIR/projects" "$FM_HOME_DIR/user-home"
printf 'off\n' > "$FM_HOME_DIR/config/herdr-presentation-spaces"
touch "$FM_HOME_DIR/state/.last-watcher-beat"
for id in pi-worker pi-signed-worker pi-raw omp-worker; do
  mkdir -p "$FM_HOME_DIR/data/$id"
  cat > "$FM_HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify the Claude provider idle limit a Firstmate-launched worker actually runs with.

## Firstmate spec
Idle in the pane; this drive reads the launched process environment.
EOF
done

"$LAB" provision "$SESSION" >/dev/null || { echo "fatal: could not provision isolated lab session"; exit 1; }

spawn() { # <id> <label> [fm-spawn args...]
  local id=$1 label=$2
  shift 2
  echo "----- $label -----"
  echo "\$ PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=$PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS fm-spawn.sh $id <project> $* --backend herdr"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_HOME="$FM_HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$@" --backend herdr --mode no-mistakes --yolo off 2>&1
  echo "spawn rc=$?"
  local wt
  wt=$(grep '^worktree=' "$FM_HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  echo "meta: $(grep -E '^(harness|backend|herdr_pane_id)=' "$FM_HOME_DIR/state/$id.meta" 2>/dev/null | tr '\n' ' ')"
}

lab() { "$LAB" run "$SESSION" "$@"; }

# Rendered output of the real Herdr pane the worker is running in.
read_pane() { # <id>
  local pane
  pane=$(grep '^herdr_pane_id=' "$FM_HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$pane" ] || { echo "(no pane recorded for $1)"; return 0; }
  echo "--- herdr pane $pane terminal output ($1) ---"
  local out
  out=$(lab pane read "$pane" --source recent --format text 2>&1)
  case "$out" in
    \{*) out=$(printf '%s' "$out" | jq -r '.result.text // .result.output // (.result.lines // [] | join("\n")) // empty' 2>/dev/null) ;;
  esac
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -12
}

wait_for_records() { # <count>
  local want=$1 i=0
  while [ "$i" -lt 30 ]; do
    [ "$(grep -c '^=== launched' "$ENVLOG")" -ge "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

echo "=== ambient (poisoned) environment seen by this drive and inherited by the lab herdr server ==="
echo "PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS=$PI_CLAUDE_CODE_PROVIDER_IDLE_TIMEOUT_MS"
echo "FM_AMBIENT_PROBE=$FM_AMBIENT_PROBE"
echo

spawn pi-worker "A. canonical Pi worker (--harness pi)" --harness pi
wait_for_records 1 || echo "warn: no harness launch record yet after A"
echo

spawn pi-signed-worker "A2. canonical pi-signed worker (--harness pi-signed)" --harness pi-signed
wait_for_records 2 || echo "warn: no harness launch record yet after A2"
echo

# The escape hatch takes the command verbatim, so the stand-in is named by its
# absolute path. fm-spawn still derives HARNESS from its basename ("pi"), which
# is exactly the RAW_LAUNCH path under test; a bare `pi` would instead resolve
# the captain's real Pi inside the pane's own login PATH.
spawn pi-raw "B. raw Pi launch escape hatch" "$FAKEBIN/pi --tui-mode regular"
wait_for_records 3 || echo "warn: no harness launch record yet after B"
echo

spawn omp-worker "C. omp worker (out of scope for the pin)" --harness omp
wait_for_records 4 || echo "warn: no harness launch record yet after C"
echo

echo "=== rendered terminal output of the real Herdr panes ==="
for id in pi-worker pi-signed-worker pi-raw omp-worker; do read_pane "$id"; done
echo

echo "=== environment recorded by each harness process actually launched in its real Herdr pane ==="
cat "$ENVLOG"
echo
echo "=== manual launch (README snippet form), no fm-spawn involved ==="
echo "\$ pi   # captain launching Pi by hand"
( PATH="$FAKEBIN:$PATH" pi >/dev/null 2>&1 & )
sleep 3
pkill -f "$FAKEBIN/pi" 2>/dev/null || true
echo "--- last record ---"
awk '/^=== launched/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$ENVLOG"
echo; echo "fm-spawn under test: $ROOT/bin/fm-spawn.sh"
