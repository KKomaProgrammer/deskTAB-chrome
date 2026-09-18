#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="7be61dfb249f6761f8e51a5ecde7a8c09c5bb826"
REPAIR_COMMIT="0268534aca2bb8786ba3111be49a1f028b91f108"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
REPAIR_URL="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$REPAIR_COMMIT/installer/repair-v17.sh"
LOADER_STATE="$STATE_DIR/loader-heartbeat-state"
LOADER_HB_PID=""
mkdir -p "$INSTALLER_DIR" "$STATE_DIR"

loader_write_heartbeat() {
  local state tmp
  state="$(cat "$LOADER_STATE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$STATE_DIR/heartbeat.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$$" "$state" > "$tmp"
  mv -f "$tmp" "$STATE_DIR/heartbeat"
}
loader_progress() {
  local p="$1" e="$2" s="$3" t="$LOADER_STATE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$p" "$e" "$s" > "$t"; mv -f "$t" "$LOADER_STATE"; loader_write_heartbeat
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$p" --el eta "$e" --es stage "$s" >/dev/null 2>&1 || true
}
loader_loop() { trap - ERR; set +e +E; while true; do loader_write_heartbeat; sleep 2; done; }
stop_loader() { set +e; [ -n "$LOADER_HB_PID" ] && kill "$LOADER_HB_PID" >/dev/null 2>&1 || true; }
trap stop_loader EXIT
fail_loader() {
  local m="$1"; loader_progress -1 0 "$m"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" --es stage "$m" >/dev/null 2>&1 || true
  exit 90
}
fetch_file() {
  local url="$1" out="$2" pin="$3" n
  for n in 1 2 3 4 5 6; do
    if curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 90 \
      -H 'Cache-Control: no-cache' "$url?pin=$pin&attempt=$n" -o "$out.tmp" && [ -s "$out.tmp" ]; then
      mv -f "$out.tmp" "$out"; return 0
    fi
    rm -f "$out.tmp"; sleep 1
  done
  return 1
}
find_root() {
  local r
  for r in "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"; do
    if [ -x "$r/usr/bin/bash" ] && [ -x "$r/usr/bin/xfce4-session" ] \
      && [ -x "$r/opt/google/chrome/google-chrome" ] && [ -f "$r/var/lib/dpkg/status" ]; then
      printf '%s\n' "$r"; return 0
    fi
  done
  return 1
}
reset_desktop() {
  local t="${TMPDIR:-$PREFIX/tmp}" p
  loader_progress 88 15 "이전 데스크톱 세션 정리"
  pkill -x termux-x11 >/dev/null 2>&1 || true
  for p in chrome google-chrome xfce4-session xfconfd xfsettingsd xfdesktop xfce4-panel; do pkill -x "$p" >/dev/null 2>&1 || true; done
  pkill -f '[d]bus-daemon.*--session' >/dev/null 2>&1 || true
  rm -f "$t/.X11-unix/X1" "$t/.X1-lock" "$t/desktab-session.env" "$STATE_DIR/desktop-status"
  rm -rf "$STATE_DIR/desktop-launch.lock"
  /system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
}
run_repair() {
  reset_desktop
  loader_progress 90 18 "데스크톱 실행 환경 수리"
  set +e
  /data/data/com.termux/files/usr/bin/bash "$REPAIR"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    stop_loader
    trap - EXIT
    exit "$rc"
  fi
}

loader_progress 1 60 "Termux bootstrap 실행 확인"
loader_loop & LOADER_HB_PID=$!
if ! command -v curl >/dev/null 2>&1; then
  loader_progress 1 60 "필수 구성 확인"
  env DEBIAN_FRONTEND=noninteractive pkg install -y curl >/dev/null 2>&1 || fail_loader "curl 설치 실패"
fi

REPAIR="$INSTALLER_DIR/desktop-repair-v17.sh"
loader_progress 2 35 "데스크톱 수리 모듈 준비"
fetch_file "$REPAIR_URL" "$REPAIR" "$REPAIR_COMMIT" || fail_loader "데스크톱 수리 모듈 다운로드 실패"
bash -n "$REPAIR" || fail_loader "데스크톱 수리 모듈 검사 실패"
chmod 700 "$REPAIR"

if [ -n "$(find_root || true)" ]; then
  touch "$STATE_DIR/ready"
  run_repair
  stop_loader; trap - EXIT; exit 0
fi

FULL="$INSTALLER_DIR/desktab-bootstrap-v11.sh"
TMP="$FULL.tmp.$$"; : > "$TMP"
loader_progress 2 300 "Linux 설치 엔진 준비"
for n in 00 01 02 03 04; do
  part="$INSTALLER_DIR/part-$n.sh"
  fetch_file "$BASE/part-$n.sh" "$part" "$INSTALLER_COMMIT" || fail_loader "installer part-$n 다운로드 실패"
  cat "$part" >> "$TMP" || fail_loader "installer part-$n 조립 실패"
  printf '\n' >> "$TMP"
done
bash -n "$TMP" || fail_loader "Linux 설치 엔진 검사 실패"
mv -f "$TMP" "$FULL"; chmod 700 "$FULL"
loader_progress 2 300 "Linux 설치 시작"
set +e
/data/data/com.termux/files/usr/bin/bash "$FULL"
rc=$?
set -e
[ "$rc" -eq 0 ] || { stop_loader; trap - EXIT; exit "$rc"; }
[ -n "$(find_root || true)" ] || fail_loader "Linux 설치 후 Ubuntu rootfs 확인 실패"
run_repair
stop_loader; trap - EXIT; exit 0
