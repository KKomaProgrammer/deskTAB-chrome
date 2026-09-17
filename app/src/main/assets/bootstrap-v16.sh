#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="7be61dfb249f6761f8e51a5ecde7a8c09c5bb826"
# v1.2.20 is the last device-proven desktop boot architecture. Keep its repair
# module pinned and only wrap the launcher with stale-X11 recovery/performance settings.
REPAIR_COMMIT="a5019dad56010812a46e3942bfb9de3c47543aee"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
REPAIR_URL="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$REPAIR_COMMIT/installer/repair-v14.sh"
LOADER_STATE="$STATE_DIR/loader-heartbeat-state"
LOADER_HB_PID=""
mkdir -p "$INSTALLER_DIR"

loader_write_heartbeat() {
  local state tmp
  state="$(cat "$LOADER_STATE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$STATE_DIR/heartbeat.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$$" "$state" > "$tmp"
  mv -f "$tmp" "$STATE_DIR/heartbeat"
}

loader_progress() {
  local pct="$1" eta="$2" stage="$3" tmp
  tmp="$LOADER_STATE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$pct" "$eta" "$stage" > "$tmp"
  mv -f "$tmp" "$LOADER_STATE"
  loader_write_heartbeat
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$pct" --el eta "$eta" --es stage "$stage" >/dev/null 2>&1 || true
}

loader_heartbeat_loop() {
  trap - ERR
  set +e
  set +E
  while true; do loader_write_heartbeat; sleep 2; done
}

stop_loader_heartbeat() {
  set +e
  if [ -n "$LOADER_HB_PID" ]; then
    kill "$LOADER_HB_PID" >/dev/null 2>&1 || true
    wait "$LOADER_HB_PID" >/dev/null 2>&1 || true
    LOADER_HB_PID=""
  fi
}
trap stop_loader_heartbeat EXIT

fail_loader() {
  local msg="$1"
  loader_progress -1 0 "$msg"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "$msg" >/dev/null 2>&1 || true
  exit 90
}

loader_progress 1 60 "초기 설정 확인"
loader_heartbeat_loop &
LOADER_HB_PID=$!

if ! command -v curl >/dev/null 2>&1; then
  loader_progress 1 60 "필수 구성 확인"
  env DEBIAN_FRONTEND=noninteractive pkg install -y curl >/dev/null 2>&1 || fail_loader "curl 설치 실패"
fi

fetch_file() {
  local url="$1" out="$2" pin="$3" attempt
  for attempt in 1 2 3 4 5 6; do
    if curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 90 \
      -H 'Cache-Control: no-cache' "$url?pin=$pin&attempt=$attempt" \
      -o "$out.tmp" && [ -s "$out.tmp" ]; then
      mv -f "$out.tmp" "$out"
      return 0
    fi
    rm -f "$out.tmp"
    sleep 1
  done
  return 1
}

reset_broken_desktop() {
  local tmpbase="${TMPDIR:-$PREFIX/tmp}" p
  loader_progress 88 20 "이전 X11/XFCE 세션 완전 초기화"

  # v1.2.21/22 can leave a living PID/socket pair whose display no longer renders.
  # A repair must not inherit that state, otherwise even the proven launcher will
  # correctly see 'already running' and attach to the broken server again.
  pkill -x termux-x11 >/dev/null 2>&1 || true
  for p in chrome google-chrome xfce4-session xfconfd xfsettingsd xfdesktop xfce4-panel; do
    pkill -x "$p" >/dev/null 2>&1 || true
  done
  pkill -f '[d]bus-daemon.*--session' >/dev/null 2>&1 || true
  rm -f "$tmpbase/.X11-unix/X1" "$tmpbase/.X1-lock" \
        "$tmpbase/desktab-session.env" "$STATE_DIR/desktop-status"
  rm -rf "$STATE_DIR/desktop-launch.lock"
  /system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
  sleep 0.25
}

wrap_proven_launcher() {
  local live="$STATE_DIR/launch.sh"
  local core="$STATE_DIR/launch-v120-core.sh"
  [ -x "$live" ] || fail_loader "검증된 Desktop launcher 생성 실패"
  cp -f "$live" "$core" || fail_loader "검증된 Desktop launcher 보존 실패"
  chmod 700 "$core"

  cat > "$live" <<'LAUNCHWRAP'
#!/data/data/com.termux/files/usr/bin/bash
set +e
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
CORE="$STATE_DIR/launch-v120-core.sh"
XSOCKET="$TMP_BASE/.X11-unix/X1"
mkdir -p "$TMP_BASE/.X11-unix"
termux-wake-lock >/dev/null 2>&1 || true
rm -f "$STATE_DIR/desktop-status"

# v1.2.20's proven order was: show Termux:X11 first -> wait -> start server/XFCE.
/system/bin/am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true

# Never trust a process alone. A process without its X socket is dead state.
if pgrep -f '[t]ermux-x11 :1' >/dev/null 2>&1 && [ ! -S "$XSOCKET" ]; then
  pkill -x termux-x11 >/dev/null 2>&1 || true
  rm -f "$XSOCKET" "$TMP_BASE/.X1-lock"
fi
if ! pgrep -f '[t]ermux-x11 :1' >/dev/null 2>&1; then
  rm -f "$XSOCKET" "$TMP_BASE/.X1-lock"
fi

sleep 0.65

# Rendering fewer physical pixels is the safest large speed win and removes no features.
if command -v termux-x11-preference >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 termux-x11-preference displayResolutionMode=scaled displayScale=60 fullscreen=true >/dev/null 2>&1 || true
  else
    termux-x11-preference displayResolutionMode=scaled displayScale=60 fullscreen=true >/dev/null 2>&1 &
  fi
fi

exec "$CORE"
LAUNCHWRAP
  chmod 700 "$live"
  bash -n "$live" || fail_loader "Desktop launcher 래퍼 검사 실패"
  printf '%s\n' '7' > "$STATE_DIR/desktop-repair-version"
}

run_proven_repair() {
  reset_broken_desktop
  loader_progress 90 18 "검증된 v1.2.20 부팅 경로 복구"
  set +e
  /data/data/com.termux/files/usr/bin/bash "$REPAIR"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail_loader "검증된 데스크톱 부팅 모듈 실행 실패"
  wrap_proven_launcher
  loader_progress 100 0 "Desktop Chrome 부팅 경로 복구 완료"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
}

REPAIR="$INSTALLER_DIR/desktop-repair-v14.sh"
loader_progress 2 35 "Desktop Chrome 실행 환경 준비"
fetch_file "$REPAIR_URL" "$REPAIR" "$REPAIR_COMMIT" || fail_loader "데스크톱 수리 모듈 다운로드 실패"
bash -n "$REPAIR" || fail_loader "데스크톱 수리 모듈 검사 실패"
chmod 700 "$REPAIR"

RUNTIME_HEALTHY=1
for ROOT in \
  "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs" \
  "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"; do
  if [ -x "$ROOT/usr/bin/xfce4-session" ] \
    && [ -x "$ROOT/usr/bin/xfce4-terminal" ] \
    && [ -x "$ROOT/opt/google/chrome/google-chrome" ] \
    && [ -f "$ROOT/var/lib/dpkg/status" ]; then
    RUNTIME_HEALTHY=0
    break
  fi
done

if [ "$RUNTIME_HEALTHY" -eq 0 ]; then
  touch "$STATE_DIR/ready"
  stop_loader_heartbeat
  trap - EXIT
  run_proven_repair
  exit 0
fi

FULL="$INSTALLER_DIR/desktab-bootstrap-v11.sh"
TMP="$FULL.tmp.$$"
: > "$TMP"
loader_progress 2 300 "Linux 설치 엔진 준비"
for n in 00 01 02 03 04; do
  part="$INSTALLER_DIR/part-$n.sh"
  url="$BASE/part-$n.sh"
  fetch_file "$url" "$part" "$INSTALLER_COMMIT" || fail_loader "installer part-$n 다운로드 실패"
  cat "$part" >> "$TMP" || fail_loader "installer part-$n 조립 실패"
  printf '\n' >> "$TMP"
done
bash -n "$TMP" || fail_loader "Linux 설치 엔진 검사 실패"
mv -f "$TMP" "$FULL"
chmod 700 "$FULL"

loader_progress 2 300 "Linux 설치 시작"
set +e
/data/data/com.termux/files/usr/bin/bash "$FULL"
FULL_RC=$?
set -e
if [ "$FULL_RC" -ne 0 ]; then
  stop_loader_heartbeat
  exit "$FULL_RC"
fi

stop_loader_heartbeat
trap - EXIT
run_proven_repair
exit 0
