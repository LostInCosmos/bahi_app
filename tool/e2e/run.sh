#!/usr/bin/env bash
# End-to-end flows on the Android emulator against the local e2e server
# (DAS-109). One command; prints PASS/FAIL per flow; a screenshot per step
# lands under build/e2e/<timestamp>/<flow>/ (gitignored, never committed).
#
#   tool/e2e/run.sh                 # every flow, in order
#   tool/e2e/run.sh flow_03_sell    # one flow (the server is reset first all the same)
#
# Knobs (environment):
#   E2E_PORT        the local server's port (8000); the app is pointed at http://10.0.2.2:$E2E_PORT
#   E2E_WINDOW=1    show the emulator's window. Headless by default: with a window the
#                   emulator crashed itself twice mid-run on this Mac (QEMU "hanging thread")
#   E2E_KEEP_EMULATOR=1  leave the emulator running afterwards (it is stopped by default, with
#                   Gradle's and Kotlin's daemons: a 16 GB Mac also runs agents, VS Code and a backend)
#   E2E_BILL_IMAGE  the photo the virtual camera shows. Default: a real bill from the local
#                   copies of the shops' uploads (../local-db/app-storage, else the backend's
#                   tests/storage), falling back to the server's generated .e2e/sample_bill.jpg.
#                   Those copies stay outside the repos; never commit one.
#   E2E_CAMERA      imagefile (default: the image fills the camera frame) or virtualscene
#                   (the image is a poster on the wall of the emulator's 3D room)
#   E2E_AVD         the virtual device (dastavez_e2e)
#   E2E_KEEP_SERVER=1  do not stop the server afterwards
#   E2E_NO_SERVER=1    the server is already up and reset (for repeated runs while developing a flow)
#
# One heavy test at a time on this machine: a run takes $HEAVY_LOCK (a directory, shared with
# any other worktree or agent that honours it) and refuses to start while another holds it.
#
# Needs: the Android SDK and JDK that `flutter doctor` reports, patrol_cli on
# PATH (`flutter pub global activate patrol_cli`), the local Postgres and
# Redis the backend's ops/e2e_server.sh needs, and ../bahi_backend checked out
# beside this repo. The AVD is created once by tool/e2e/create_avd.sh.
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND_DIR="${E2E_BACKEND_DIR:-$APP_DIR/../bahi_backend}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$HOME/.pub-cache/bin:$PATH"
AVD="${E2E_AVD:-dastavez_e2e}"
PORT="${E2E_PORT:-8000}"
SERIAL="emulator-5554"
PACKAGE="com.dastavez.bahi"
RUN_DIR="$APP_DIR/build/e2e/$(date +%Y%m%d-%H%M%S)"
ALL_FLOWS=(flow_01_signup flow_02_photograph flow_03_sell flow_04_export flow_05_logout_login)
FLOWS=("$@"); [ $# -eq 0 ] && FLOWS=("${ALL_FLOWS[@]}")

say() { printf '\n== %s\n' "$*"; }
die() { printf 'e2e: %s\n' "$*" >&2; exit 2; }

# --- 0. one heavy test at a time, and nothing left running afterwards ----------
HEAVY_LOCK="${E2E_HEAVY_LOCK:-/tmp/dastavez-heavy-test.lock}"
WAIT_MAX="${E2E_WAIT_MINUTES:-90}"
MIN_FREE="${E2E_MIN_FREE_PCT:-35}"   # memory_pressure's "free percentage" before the emulator boots
free_pct() { memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2+0}'; }
waited=0
# Another engineer's heavy test (an emulator, a simulator, Chromium, a load test) holds the
# lock: wait for it rather than run two at once. Then wait for memory, which agents, VS Code
# and builds also use.
until mkdir "$HEAVY_LOCK" 2>/dev/null; do
  [ "$waited" -ge "$WAIT_MAX" ] && die "still busy after $WAIT_MAX min: $(cat "$HEAVY_LOCK/owner" 2>/dev/null || echo unknown) (remove $HEAVY_LOCK if that run is gone)"
  [ "$waited" -eq 0 ] && say "waiting for another heavy test: $(cat "$HEAVY_LOCK/owner" 2>/dev/null || echo unknown)"
  sleep 60; waited=$((waited + 1))
done
echo "e2e run.sh in $(pwd) since $(date '+%H:%M') (pid $$)" >"$HEAVY_LOCK/owner"
cleanup() {
  if [ "${E2E_KEEP_EMULATOR:-}" != 1 ]; then
    adb -s "$SERIAL" emu kill >/dev/null 2>&1
    (cd "$APP_DIR/android" && ./gradlew --stop >/dev/null 2>&1)
    pkill -f KotlinCompileDaemon >/dev/null 2>&1
  fi
  rm -rf "$HEAVY_LOCK"
}
trap cleanup EXIT
while [ "$(free_pct)" -lt "$MIN_FREE" ] 2>/dev/null; do
  [ "$waited" -ge "$WAIT_MAX" ] && die "memory still under $MIN_FREE% free after $WAIT_MAX min"
  say "waiting for memory: $(free_pct)% free, want $MIN_FREE%"
  sleep 60; waited=$((waited + 1))
done

for tool in adb emulator patrol flutter python3; do
  command -v "$tool" >/dev/null || die "$tool not on PATH (see the header of this script)"
done
[ -d "$BACKEND_DIR" ] || die "backend not found at $BACKEND_DIR (set E2E_BACKEND_DIR)"

# --- 1. the server: fresh seed every run -------------------------------------
if [ "${E2E_NO_SERVER:-}" != 1 ]; then
  say "server: ops/e2e_server.sh up (port $PORT)"
  # `reset` refuses when the server is not up (its `status` exits 0 either way), so: reset, else up.
  if ! (cd "$BACKEND_DIR" && E2E_PORT="$PORT" ops/e2e_server.sh reset); then
    (cd "$BACKEND_DIR" && E2E_PORT="$PORT" ops/e2e_server.sh up) || die "server did not start"
  fi
fi
SEED="$BACKEND_DIR/.e2e/seed.json"
[ -f "$SEED" ] || die "no seed at $SEED"
seed() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d[int(k)] if k.isdigit() else d[k]
print(d)" "$SEED" "$1"; }
# A REAL bill photo by default (user decision 2026-10-22), from the local copies
# of the shops' uploads, which live outside every repo and are never committed;
# the server's generated stand-in only when no copy is on this Mac.
BILL="${E2E_BILL_IMAGE:-}"
if [ -z "$BILL" ]; then
  for candidate in "$APP_DIR/../local-db/app-storage/9/3746f8e654a84a1c80b01b738f7a6f91.jpg" \
                   "$BACKEND_DIR/tests/storage/35/1168505745b34629b56d70ba21bb10d3.jpg" \
                   "$(seed sample_bill_image)"; do
    [ -f "$candidate" ] && { BILL="$candidate"; break; }
  done
fi
[ -f "$BILL" ] || die "bill image not found: $BILL"
CAMERA="${E2E_CAMERA:-imagefile}"

# --- 2. the emulator ---------------------------------------------------------
booted() { [ "$(adb -s $SERIAL shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
# The camera image is fixed at boot, so a running emulator that shows another
# image (or mode) is restarted rather than reused.
BOOTED_WITH="$APP_DIR/build/e2e/.booted_with"
WANT="$CAMERA $BILL"
if booted && [ "$(cat "$BOOTED_WITH" 2>/dev/null)" != "$WANT" ]; then
  say "emulator: running with another camera image; restarting"
  adb -s $SERIAL emu kill >/dev/null 2>&1
  for _ in $(seq 1 20); do booted || break; sleep 1; done
fi
if ! booted; then
  say "emulator: booting $AVD with camera $CAMERA $(basename "$BILL")"
  case "$CAMERA" in
    imagefile)    CAM=(-camera-back "imagefile:$BILL") ;;
    virtualscene) CAM=(-camera-back virtualscene -virtualscene-poster "wall=$BILL") ;;
    *) die "E2E_CAMERA must be imagefile or virtualscene" ;;
  esac
  WIN=(-no-window -no-audio); [ "${E2E_WINDOW:-}" = 1 ] && WIN=()
  mkdir -p "$RUN_DIR"
  # ${WIN[@]+"${WIN[@]}"}: an empty array is "unbound" to bash 3.2 under set -u.
  nohup emulator -avd "$AVD" -port 5554 -no-boot-anim -no-snapshot "${CAM[@]}" ${WIN[@]+"${WIN[@]}"} \
    >"$RUN_DIR/emulator.log" 2>&1 &
  for _ in $(seq 1 60); do booted && break; sleep 3; done
  booted || die "emulator did not boot in 3 minutes (see $RUN_DIR/emulator.log)"
  echo "$WANT" >"$BOOTED_WITH"
  # Animations off: a settle that waits on them is time wasted, and a
  # mid-animation tap is the classic flake.
  for s in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb -s $SERIAL shell settings put global $s 0
  done
else
  say "emulator: already running ($SERIAL) with $(basename "$BILL")"
fi

# A fresh install once per run; Patrol wipes the app's data before each flow.
adb -s $SERIAL uninstall "$PACKAGE" >/dev/null 2>&1 || true

# --- 3. the flows ------------------------------------------------------------
DEFINES=(
  --dart-define "E2E_BASE_URL=http://10.0.2.2:$PORT"
  --dart-define "E2E_EMAIL=$(seed login.email)"
  --dart-define "E2E_PASSWORD=$(seed login.password)"
  --dart-define "E2E_PRODUCT=$(seed products.0.name)"
  --dart-define "E2E_VENDOR=$(seed supplier.name)"
)
mkdir -p "$RUN_DIR"
RESULTS="$RUN_DIR/results.txt"; : >"$RESULTS"   # "<flow> <verdict>" per line (bash 3.2: no maps)
result() { grep "^$1 " "$RESULTS" | cut -d' ' -f2-; }
cd "$APP_DIR"
for flow in "${FLOWS[@]}"; do
  target="integration_test/${flow}_test.dart"
  [ -f "$target" ] || { echo "$flow MISSING ($target)" >>"$RESULTS"; continue; }
  say "flow $flow"
  rm -rf integration_test/screenshots
  # Patrol exits 0 when it found no test to run (an empty test APK), so the
  # summary line is checked too.
  if patrol test -d "$SERIAL" -t "$target" "${DEFINES[@]}" <"/dev/null" >"$RUN_DIR/$flow.log" 2>&1 \
     && grep -q "Successful: 1" "$RUN_DIR/$flow.log"; then
    echo "$flow PASS" >>"$RESULTS"
  else
    echo "$flow FAIL (log: build/e2e/$(basename "$RUN_DIR")/$flow.log)" >>"$RESULTS"
  fi
  # Patrol nests each shot under <class>/<method>/<millis>_<tag>.png; keep just <tag>.png.
  if [ -d integration_test/screenshots ]; then
    mkdir -p "$RUN_DIR/$flow"
    find integration_test/screenshots -name '*.png' | while read -r png; do
      mv "$png" "$RUN_DIR/$flow/$(basename "$png" | sed -E 's/^[0-9]+_//')"
    done
    rm -rf integration_test/screenshots
  fi
  printf '   %s: %s\n' "$flow" "$(result "$flow")"
done

# --- 4. the verdict ----------------------------------------------------------
say "results (screenshots and logs: $RUN_DIR)"
fail=0
for flow in "${FLOWS[@]}"; do
  printf '%-18s %s\n' "$flow" "$(result "$flow")"
  [ "$(result "$flow")" = PASS ] || fail=1
done
if [ "${E2E_NO_SERVER:-}" != 1 ] && [ "${E2E_KEEP_SERVER:-}" != 1 ]; then
  (cd "$BACKEND_DIR" && E2E_PORT="$PORT" ops/e2e_server.sh down >/dev/null 2>&1)
fi
exit $fail
