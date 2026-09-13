#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

# Immutable loader for the validated v11 rootfs installer plus the lightweight
# desktop repair. Existing working Ubuntu installations are repaired in seconds
# without downloading the Linux runtime again.
APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="0419682c3721b8c836585d781838ba9f3cdd6023"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
REPAIR_URL="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/repair-v12.sh"
mkdir -p "$INSTALLER_DIR"

fail_loader() {
  local msg="$1"
  printf '[deskTAB loader] %s\n' "$msg" >&2
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "설치 엔진 로드 실패 · $msg" >/dev/null 2>&1 || true
  exit 90
}

if ! command -v curl >/dev/null 2>&1; then
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

REPAIR="$INSTALLER_DIR/desktop-repair-v12.sh"
fetch_file "$REPAIR_URL" "$REPAIR" || fail_loader "desktop repair 다운로드 실패"
bash -n "$REPAIR" || fail_loader "desktop repair 셸 문법 검사 실패"
chmod 700 "$REPAIR"

# If the v1.2.17 rootfs is already healthy, only patch session/app launch behavior.
# This avoids another ~1 GB runtime download for the repeated-launch fix.
if [ -f "$STATE_DIR/ready" ] \
  && command -v proot-distro >/dev/null 2>&1 \
  && proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
       'test -x /usr/bin/xfce4-session && command -v google-chrome-stable >/dev/null' >/dev/null 2>&1; then
  exec /data/data/com.termux/files/usr/bin/bash "$REPAIR"
fi

FULL="$INSTALLER_DIR/desktab-bootstrap-v11.sh"
TMP="$FULL.tmp.$$"
: > "$TMP"
for n in 00 01 02 03 04; do
  part="$INSTALLER_DIR/part-$n.sh"
  url="$BASE/part-$n.sh"
  fetch_file "$url" "$part" || fail_loader "installer part-$n 다운로드 실패"
  cat "$part" >> "$TMP" || fail_loader "installer part-$n 조립 실패"
done

bash -n "$TMP" || fail_loader "installer 셸 문법 검사 실패"
mv -f "$TMP" "$FULL"
chmod 700 "$FULL"

# A fresh install still uses the thoroughly validated rootfs installer. Immediately
# afterwards apply the same launcher/session repair used by existing installations.
if /data/data/com.termux/files/usr/bin/bash "$FULL"; then
  exec /data/data/com.termux/files/usr/bin/bash "$REPAIR"
fi
exit $?
