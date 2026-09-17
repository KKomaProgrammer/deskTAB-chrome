#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="7be61dfb249f6761f8e51a5ecde7a8c09c5bb826"
REPAIR_COMMIT="a1cc899f80f20e9a65abcb14f72f786480584d97"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
REPAIR_URL="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$REPAIR_COMMIT/installer/repair-v16.sh"
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

REPAIR="$INSTALLER_DIR/desktop-repair-v16.sh"
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
  loader_progress 90 18 "기존 Linux 환경 확인 완료 · 빠른 수리"
  stop_loader_heartbeat
  trap - EXIT
  exec /data/data/com.termux/files/usr/bin/bash "$REPAIR"
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
exec /data/data/com.termux/files/usr/bin/bash "$REPAIR"
