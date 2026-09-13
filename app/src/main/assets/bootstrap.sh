#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

# v1.2.19 loader: publish a heartbeat immediately, repair any already-working
# Ubuntu without depending on a stale ready marker, and only fall back to the
# full validated runtime installer when the Linux environment is genuinely absent.
APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="569a994928c72b4e97af65950cef01b65389aee0"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
REPAIR_URL="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/repair-v13.sh"
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
  while true; do
    loader_write_heartbeat
    sleep 2
  done
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
  printf '[deskTAB loader] %s\n' "$msg" >&2
  loader_progress -1 0 "설치 엔진 로드 실패 · $msg"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "설치 엔진 로드 실패 · $msg" >/dev/null 2>&1 || true
  exit 90
}

# The Android watchdog now sees a valid heartbeat before curl, PRoot health checks,
# old-process cleanup, or any network request can take time.
loader_progress 1 60 "Termux bootstrap 실행 확인 · 기존 Linux 환경 판정"
loader_heartbeat_loop &
LOADER_HB_PID=$!

if ! command -v curl >/dev/null 2>&1; then
  loader_progress 1 60 "bootstrap 준비 · curl 확인"
  env DEBIAN_FRONTEND=noninteractive pkg install -y curl >/dev/null 2>&1 || fail_loader "curl 설치 실패"
fi

fetch_file() {
  local url="$1" out="$2" attempt
  for attempt in 1 2 3 4 5 6; do
    if curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 90 \
      -H 'Cache-Control: no-cache' "$url?pin=$INSTALLER_COMMIT&attempt=$attempt" \
      -o "$out.tmp" && [ -s "$out.tmp" ]; then
      mv -f "$out.tmp" "$out"
      return 0
    fi
    rm -f "$out.tmp"
    sleep 1
  done
  return 1
}

REPAIR="$INSTALLER_DIR/desktop-repair-v13.sh"
loader_progress 1 45 "반복 실행 수리 엔진 확인"
fetch_file "$REPAIR_URL" "$REPAIR" || fail_loader "desktop repair 다운로드 실패"
bash -n "$REPAIR" || fail_loader "desktop repair 셸 문법 검사 실패"
chmod 700 "$REPAIR"

# Do NOT require STATE_DIR/ready here. Older failed/repaired versions could lose
# that marker even though the Ubuntu rootfs itself was perfectly healthy. The
# actual binaries inside PRoot are the source of truth.
loader_progress 1 35 "기존 Ubuntu/Chrome 실제 상태 확인"
RUNTIME_HEALTHY=1
if command -v proot-distro >/dev/null 2>&1; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && command -v google-chrome-stable >/dev/null'
    RUNTIME_HEALTHY=$?
  else
    proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && command -v google-chrome-stable >/dev/null'
    RUNTIME_HEALTHY=$?
  fi
  set -e
else
  RUNTIME_HEALTHY=1
fi

if [ "$RUNTIME_HEALTHY" -eq 0 ]; then
  touch "$STATE_DIR/ready"
  loader_progress 90 15 "기존 Linux 환경 정상 · 재다운로드 없이 빠른 수리"
  stop_loader_heartbeat
  trap - EXIT
  exec /data/data/com.termux/files/usr/bin/bash "$REPAIR"
fi

FULL="$INSTALLER_DIR/desktab-bootstrap-v11.sh"
TMP="$FULL.tmp.$$"
: > "$TMP"
loader_progress 1 300 "Linux 설치/복구 엔진 준비"
for n in 00 01 02 03 04; do
  part="$INSTALLER_DIR/part-$n.sh"
  url="$BASE/part-$n.sh"
  fetch_file "$url" "$part" || fail_loader "installer part-$n 다운로드 실패"
  cat "$part" >> "$TMP" || fail_loader "installer part-$n 조립 실패"
done

bash -n "$TMP" || fail_loader "installer 셸 문법 검사 실패"
mv -f "$TMP" "$FULL"
chmod 700 "$FULL"

# Keep the loader heartbeat alive while the full installer's ancestor-safe cleanup
# runs. Once the full installer publishes its own heartbeat, lower 1% loader heartbeats
# are ignored by the Android monotonic-progress logic.
loader_progress 1 300 "Linux 설치/복구 엔진 시작"
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
