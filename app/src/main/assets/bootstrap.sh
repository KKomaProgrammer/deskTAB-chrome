#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

# Small immutable loader for the fully validated v10 installer.  The installer is split
# into repository fragments only to keep the Android asset compact; all fragments are
# pinned to one Git commit and the reconstructed script is verified before execution.
APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v10"
INSTALLER_COMMIT="5a24aa211c339066dd5e9c7b54e994b08ed52677"
INSTALLER_SHA256="b90141471bc8242f1d626cdbfc58b2b508742a015d0b626233401289ed6599d0"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
mkdir -p "$INSTALLER_DIR"

fail_loader() {
  local msg="$1"
  printf '[deskTAB loader] %s\n' "$msg" >&2
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "설치 엔진 로드 실패 · $msg" >/dev/null 2>&1 || true
  exit 90
}

# A new Termux installation may not yet have curl/coreutils. Bootstrap only these tiny
# prerequisites here; the full v10 installer performs the normal package validation.
if ! command -v curl >/dev/null 2>&1; then
  env DEBIAN_FRONTEND=noninteractive pkg install -y curl >/dev/null 2>&1 || fail_loader "curl 설치 실패"
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  env DEBIAN_FRONTEND=noninteractive pkg install -y coreutils >/dev/null 2>&1 || fail_loader "coreutils 설치 실패"
fi

FULL="$INSTALLER_DIR/desktab-bootstrap-v10.sh"
TMP="$FULL.tmp.$$"
: > "$TMP"
for n in 00 01 02 03 04; do
  part="$INSTALLER_DIR/part-$n.sh"
  url="$BASE/part-$n.sh?installer=$INSTALLER_COMMIT"
  ok=0
  for attempt in 1 2 3 4 5 6; do
    if curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 90 \
      -H 'Cache-Control: no-cache' "$url" -o "$part.tmp" && [ -s "$part.tmp" ]; then
      mv -f "$part.tmp" "$part"
      ok=1
      break
    fi
    rm -f "$part.tmp"
    sleep 1
  done
  [ "$ok" -eq 1 ] || fail_loader "installer part-$n 다운로드 실패"
  cat "$part" >> "$TMP" || fail_loader "installer part-$n 조립 실패"
done

actual="$(sha256sum "$TMP" | awk '{print $1}')"
[ "$actual" = "$INSTALLER_SHA256" ] || fail_loader "installer SHA-256 불일치"
bash -n "$TMP" || fail_loader "installer 셸 문법 검사 실패"
mv -f "$TMP" "$FULL"
chmod 700 "$FULL"
exec /data/data/com.termux/files/usr/bin/bash "$FULL"
