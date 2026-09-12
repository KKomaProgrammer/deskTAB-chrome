#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
CACHE_DIR="$STATE_DIR/runtime-cache"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/runtime-image/runtime"
CURRENT_STAGE="고속 설치 시작"
mkdir -p "$STATE_DIR" "$CACHE_DIR"

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_STAGE="$*"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$pct" --el eta "$eta" --es stage "$CURRENT_STAGE" >/dev/null 2>&1 || true
}

failed() {
  local code=$?
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "실패: $CURRENT_STAGE (exit $code)" >/dev/null 2>&1 || true
  exit "$code"
}
trap failed ERR

# 이전 설치가 남아 있으면 먼저 종료해 apt/rootfs 잠금 충돌을 없앤다.
pkill -f 'proot-distro install ubuntu' >/dev/null 2>&1 || true
pkill -f 'proot.*installed-rootfs/ubuntu' >/dev/null 2>&1 || true
pkill -f 'proot.*containers/ubuntu' >/dev/null 2>&1 || true
pkill -f '[a]pt-get install.*termux-x11' >/dev/null 2>&1 || true
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

# 앱이 Termux 명령의 실제 시작을 즉시 확인하게 한다.
progress 2 285 "Termux 명령 실행 확인 · 저장소 초기화"
mkdir -p "$PREFIX/etc/apt/sources.list.d"
printf '%s\n' 'deb https://packages.termux.dev/apt/termux-main stable main' > "$PREFIX/etc/apt/sources.list"
printf '%s\n' 'deb https://packages.termux.dev/apt/termux-x11 x11 main' > "$PREFIX/etc/apt/sources.list.d/x11.list"
apt-get update -o Acquire::Languages=none -o Acquire::Retries=3

progress 7 250 "X11 · PRoot · 오디오 최소 구성 설치"
apt-get install -y termux-x11-nightly proot-distro pulseaudio

# 설치가 끝날 때까지 기다리지 않고 X11 서버를 바로 올린다.
# 사용자가 Termux:X11을 열었을 때 'Not connected'가 계속 남지 않게 한다.
progress 9 235 "Termux:X11 :1 서버 시작"
export XDG_RUNTIME_DIR="$TMPDIR"
pkill -f 'termux-x11 :1' >/dev/null 2>&1 || true
nohup termux-x11 :1 >/dev/null 2>&1 &
sleep 2

progress 11 220 "사전 구성 Linux 이미지 정보 확인"
MANIFEST="$CACHE_DIR/manifest.txt"
curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 \
  "$RUNTIME_BASE/manifest.txt" -o "$MANIFEST"
TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2}' "$MANIFEST")"
FORMAT="$(awk '$1=="FORMAT"{print $2}' "$MANIFEST")"
PART_COUNT="$(awk '$1=="PART"{n++} END{print n+0}' "$MANIFEST")"
if [ -z "$TOTAL_SIZE" ] || [ "$TOTAL_SIZE" -le 0 ] || [ "$PART_COUNT" -le 0 ]; then
  echo "Invalid fast-runtime manifest" >&2
  exit 42
fi
if [ "$FORMAT" != "xz" ]; then
  echo "Unsupported runtime format: $FORMAT" >&2
  exit 45
fi

progress 13 205 "Linux 이미지 병렬 다운로드 시작 ($PART_COUNT개 조각)"
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
  PCT=$((13 + DONE * 65 / TOTAL_SIZE))
  [ "$PCT" -gt 78 ] && PCT=78
  if [ "$DONE" -gt 1048576 ]; then
    ETA=$(((TOTAL_SIZE - DONE) * ELAPSED / DONE + 55))
  else
    ETA=205
  fi
  MB=$((DONE / 1048576))
  TOTAL_MB=$((TOTAL_SIZE / 1048576))
  progress "$PCT" "$ETA" "Linux 이미지 다운로드 ${MB}/${TOTAL_MB}MB"
  sleep 1
done
wait "$DL_PID"

progress 79 50 "다운로드 무결성 검사"
while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  actual_size=$(stat -c %s "$CACHE_DIR/$part")
  [ "$actual_size" = "$size" ] || { echo "Size mismatch: $part" >&2; exit 43; }
  echo "$sha  $CACHE_DIR/$part" | sha256sum -c - >/dev/null
done < "$MANIFEST"
CALC_SHA=$(while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") | sha256sum | awk '{print $1}')
[ "$CALC_SHA" = "$ARCHIVE_SHA" ] || { echo "Archive checksum mismatch" >&2; exit 44; }

progress 82 42 "Ubuntu + XFCE + Chrome 이미지 고속 해제"
LEGACY_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
MODERN_CONTAINER="$PREFIX/var/lib/proot-distro/containers/ubuntu"
rm -rf "$LEGACY_ROOT" "$MODERN_CONTAINER"
mkdir -p "$LEGACY_ROOT"
while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") \
  | xz -dc \
  | tar -xpf - -C "$LEGACY_ROOT"

progress 94 18 "Linux 네트워크 및 PRoot 등록"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'

progress 97 8 "원클릭 Chrome 실행 환경 구성"
cat >"$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
export XDG_RUNTIME_DIR="$TMPDIR"
if ! pgrep -f "termux-x11 :1" >/dev/null 2>&1; then
  termux-x11 :1 >/dev/null 2>&1 &
  sleep 1
fi
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
if command -v pactl >/dev/null 2>&1; then
  if ! pactl list modules short 2>/dev/null | grep -q 'module-native-protocol-tcp'; then
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
  fi
fi
export PULSE_SERVER=127.0.0.1
exec proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
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

rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
printf '%s\n' '4' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
