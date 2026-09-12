#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

# Small immutable loader for the validated v11 installer. Every fragment is fetched
# from one immutable Git commit, then the reconstructed script is syntax-checked
# before execution. The commit pin prevents mixed installer versions.
APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
INSTALLER_DIR="$STATE_DIR/installer-v11"
INSTALLER_COMMIT="8ac14c4e0a86106be3b908e27cee7d49d7ec118d"
BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$INSTALLER_COMMIT/installer/v10"
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

FULL="$INSTALLER_DIR/desktab-bootstrap-v11.sh"
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

# All fragments came from the same immutable commit. Syntax validation catches a
# truncated or malformed response without relying on a mutable branch or cache.
bash -n "$TMP" || fail_loader "installer 셸 문법 검사 실패"
mv -f "$TMP" "$FULL"
chmod 700 "$FULL"
exec /data/data/com.termux/files/usr/bin/bash "$FULL"
