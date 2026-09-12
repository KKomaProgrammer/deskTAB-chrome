#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
STATE_DIR="$HOME/.desktab"
CACHE_DIR="$STATE_DIR/runtime-cache"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/runtime-image/runtime"
CURRENT_STAGE="고속 설치 시작"
mkdir -p "$STATE_DIR" "$CACHE_DIR"

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_STAGE="$*"
  /system/bin/am broadcast -a "$APP_PACKAGE.SETUP_PROGRESS" -p "$APP_PACKAGE" \
    --ei progress "$pct" --el eta "$eta" --es stage "$CURRENT_STAGE" >/dev/null 2>&1 || true
}

failed() {
  local code=$?
  /system/bin/am broadcast -a "$APP_PACKAGE.SETUP_FAILED" -p "$APP_PACKAGE" \
    --es stage "실패: $CURRENT_STAGE (exit $code)" >/dev/null 2>&1 || true
  exit "$code"
}
trap failed ERR

# v1.1.x의 장시간 설치가 남아 있으면 새 고속 설치가 package-manager lock에 막히지 않도록 정리한다.
pkill -f 'proot-distro install ubuntu' >/dev/null 2>&1 || true
pkill -f 'apt-get install -y xfce4' >/dev/null 2>&1 || true
pkill -f 'apt-get install -y fonts-noto' >/dev/null 2>&1 || true
pkill -f 'google-chrome-stable_current_.*deb' >/dev/null 2>&1 || true
pkill -f '[a]pt.*update' >/dev/null 2>&1 || true
sleep 1

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  progress 1 0 "현재 고속 이미지가 지원하지 않는 ABI: $ARCH"
  echo "Fast runtime currently requires ARM64/aarch64." >&2
  exit 41
fi

progress 2 280 "Termux 저장소 고속 초기화"
mkdir -p "$PREFIX/etc/apt/sources.list.d"
printf '%s\n' 'deb https://packages.termux.dev/apt/termux-main stable main' > "$PREFIX/etc/apt/sources.list"
printf '%s\n' 'deb https://packages.termux.dev/apt/termux-x11 x11 main' > "$PREFIX/etc/apt/sources.list.d/x11.list"
apt-get update -o Acquire::Languages=none -o Acquire::Retries=3

progress 6 250 "X11 · PRoot · 오디오 구성요소 설치"
apt-get install -y x11-repo termux-x11-nightly proot-distro pulseaudio curl pigz ca-certificates

progress 10 225 "미리 구성된 Linux 이미지 정보 확인"
MANIFEST="$CACHE_DIR/manifest.txt"
curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 \
  "$RUNTIME_BASE/manifest.txt" -o "$MANIFEST"
TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2}' "$MANIFEST")"
PART_COUNT="$(awk '$1=="PART"{n++} END{print n+0}' "$MANIFEST")"
if [ -z "$TOTAL_SIZE" ] || [ "$TOTAL_SIZE" -le 0 ] || [ "$PART_COUNT" -le 0 ]; then
  echo "Invalid fast-runtime manifest" >&2
  exit 42
fi

# 이전 중단 다운로드는 이어받는다. 각 조각은 GitHub raw CDN에서 병렬로 받는다.
progress 12 210 "Linux 이미지 병렬 다운로드 시작 ($PART_COUNT개 조각)"
export CACHE_DIR RUNTIME_BASE
awk '$1=="PART"{print $2}' "$MANIFEST" | \
  xargs -P 6 -n 1 sh -c '
    p="$1"
    out="$CACHE_DIR/$p"
    url="$RUNTIME_BASE/$p"
    if [ -f "$out" ]; then
      curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 -C - "$url" -o "$out" || {
        rm -f "$out"
        curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 "$url" -o "$out"
      }
    else
      curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 "$url" -o "$out"
    fi
  ' _ &
DL_PID=$!
START_TS=$(date +%s)
while kill -0 "$DL_PID" >/dev/null 2>&1; do
  DONE=0
  while read -r _ part _ _; do
    f="$CACHE_DIR/$part"
    if [ -f "$f" ]; then
      s=$(stat -c %s "$f" 2>/dev/null || echo 0)
      DONE=$((DONE + s))
    fi
  done < <(awk '$1=="PART"{print}' "$MANIFEST")
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  [ "$ELAPSED" -lt 1 ] && ELAPSED=1
  PCT=$((12 + DONE * 64 / TOTAL_SIZE))
  [ "$PCT" -gt 76 ] && PCT=76
  if [ "$DONE" -gt 1048576 ]; then
    ETA=$(((TOTAL_SIZE - DONE) * ELAPSED / DONE + 70))
  else
    ETA=210
  fi
  MB=$((DONE / 1048576))
  TOTAL_MB=$((TOTAL_SIZE / 1048576))
  progress "$PCT" "$ETA" "Linux 이미지 다운로드 ${MB}/${TOTAL_MB}MB"
  sleep 1
done
wait "$DL_PID"

progress 77 70 "다운로드 무결성 검사"
while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  actual_size=$(stat -c %s "$CACHE_DIR/$part")
  [ "$actual_size" = "$size" ] || { echo "Size mismatch: $part" >&2; exit 43; }
  echo "$sha  $CACHE_DIR/$part" | sha256sum -c - >/dev/null
 done < "$MANIFEST"
CALC_SHA=$(while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") | sha256sum | awk '{print $1}')
[ "$CALC_SHA" = "$ARCHIVE_SHA" ] || { echo "Archive checksum mismatch" >&2; exit 44; }

progress 80 55 "Ubuntu + XFCE + Chrome 이미지 고속 해제"
LEGACY_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/desktab-ubuntu"
MODERN_ROOT="$PREFIX/var/lib/proot-distro/containers/desktab-ubuntu"
rm -rf "$LEGACY_ROOT" "$MODERN_ROOT"
mkdir -p "$LEGACY_ROOT"
while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") \
  | pigz -dc \
  | tar -xpf - -C "$LEGACY_ROOT"

progress 92 25 "Linux 네트워크 및 PRoot 등록"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"
proot-distro login desktab-ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'

progress 96 12 "원클릭 Chrome 실행 환경 구성"
cat >"$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
export XDG_RUNTIME_DIR="$TMPDIR"
if ! pgrep -f "termux-x11 :1" >/dev/null 2>&1; then
  termux-x11 :1 >/dev/null 2>&1 &
  sleep 1
fi
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
export PULSE_SERVER=127.0.0.1
exec proot-distro login desktab-ubuntu --shared-tmp -- /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  export PULSE_SERVER=127.0.0.1
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  pkill -f google-chrome-stable >/dev/null 2>&1 || true
  pkill -f xfce4-session >/dev/null 2>&1 || true
  exec dbus-launch --exit-with-session xfce4-session
'
LAUNCH
chmod +x "$STATE_DIR/launch.sh"

# 설치 후 압축 조각은 삭제해 저장 공간을 회수한다. 설치된 Linux/Chrome 데이터는 유지된다.
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
printf '%s\n' '2' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료"
/system/bin/am broadcast -a "$APP_PACKAGE.SETUP_DONE" -p "$APP_PACKAGE" >/dev/null 2>&1 || true
