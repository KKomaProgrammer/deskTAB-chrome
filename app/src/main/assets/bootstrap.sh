#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
CACHE_DIR="$STATE_DIR/runtime-cache"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/runtime-image/runtime"
PID_FILE="$STATE_DIR/setup.pid"
CURRENT_STAGE="고속 설치 시작"
mkdir -p "$STATE_DIR" "$CACHE_DIR"

log() {
  printf '[deskTAB] %s\n' "$*"
}

broadcast_progress() {
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$1" --el eta "$2" --es stage "$3" >/dev/null 2>&1 || true
}

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_STAGE="$*"
  log "$pct% · $CURRENT_STAGE"
  broadcast_progress "$pct" "$eta" "$CURRENT_STAGE"
}

failed() {
  local code=$?
  local line="${BASH_LINENO[0]:-?}"
  set +e
  log "오류 · line $line · exit $code · $CURRENT_STAGE"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "실패: $CURRENT_STAGE · line $line · exit $code" >/dev/null 2>&1
  exit "$code"
}

cleanup() {
  rm -f "$PID_FILE" >/dev/null 2>&1 || true
}

trap failed ERR
trap cleanup EXIT

log "=========================================="
log "deskTAB Chrome Linux bootstrap v5 시작"
log "HOME=$HOME"
log "PREFIX=${PREFIX:-<unset>}"
log "ARCH=$(uname -m)"
log "=========================================="

if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "Termux PREFIX 환경이 없습니다." >&2
  exit 30
fi

if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" >/dev/null 2>&1; then
    progress 2 0 "이미 실행 중인 설치 프로세스 감지 (PID $OLD_PID)"
    exit 0
  fi
fi
printf '%s\n' "$$" > "$PID_FILE"

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  progress 1 0 "현재 고속 이미지가 지원하지 않는 ABI: $ARCH"
  echo "Fast runtime currently requires ARM64/aarch64." >&2
  exit 41
fi

progress 2 285 "Termux 로컬 bootstrap 실행 확인"

# 기존 프로세스를 pkill로 광범위하게 종료하지 않는다. 이전 버전은 이 과정에서
# 새 shell까지 함께 종료될 가능성이 있었으므로 v5에서는 패키지 관리자가 직접
# 잠금/복구를 처리하도록 둔다.
if command -v dpkg >/dev/null 2>&1; then
  dpkg --configure -a || true
fi

progress 3 275 "Termux 저장소 확인"
apt-get update -o Acquire::Languages=none -o Acquire::Retries=3

# x11-repo가 아직 활성화되지 않은 깨끗한 Termux에서도 공식 방식으로 추가한다.
if ! apt-cache show termux-x11-nightly >/dev/null 2>&1; then
  progress 5 265 "공식 Termux X11 저장소 추가"
  apt-get install -y x11-repo
  apt-get update -o Acquire::Languages=none -o Acquire::Retries=3
fi

progress 7 250 "X11 · PRoot · 오디오 최소 구성 설치"
apt-get install -y termux-x11-nightly proot-distro pulseaudio curl xz-utils tar coreutils procps

progress 9 235 "Termux:X11 :1 서버 시작"
export XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
if ! pgrep -f 'termux-x11 :1' >/dev/null 2>&1; then
  termux-x11 :1 >"$STATE_DIR/x11.log" 2>&1 &
  sleep 2
fi

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

download_part() {
  local p="$1"
  local out="$CACHE_DIR/$p"
  local url="$RUNTIME_BASE/$p"
  if [ -f "$out" ]; then
    curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 -C - "$url" -o "$out" || {
      rm -f "$out"
      curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 "$url" -o "$out"
    }
  else
    curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 "$url" -o "$out"
  fi
}
export -f download_part

# xargs 의존성을 없애고 bash 자체 background job으로 병렬 다운로드한다.
ACTIVE=0
while read -r part; do
  download_part "$part" &
  ACTIVE=$((ACTIVE + 1))
  if [ "$ACTIVE" -ge 6 ]; then
    wait -n
    ACTIVE=$((ACTIVE - 1))
  fi
done < <(awk '$1=="PART"{print $2}' "$MANIFEST")

START_TS=$(date +%s)
while jobs -pr | grep -q .; do
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
wait

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

progress 94 18 "Linux 네트워크 및 PRoot 확인"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'

progress 97 8 "원클릭 Chrome 실행 환경 구성"
cat >"$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
export XDG_RUNTIME_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
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
printf '%s\n' '5' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
log "설정이 완료되었습니다. deskTAB Chrome 앱으로 돌아가 Desktop Chrome 실행을 누르세요."
