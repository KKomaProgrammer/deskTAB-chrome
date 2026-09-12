#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
CACHE_DIR="$STATE_DIR/runtime-cache"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/runtime-image/runtime"
LOCK_DIR="$STATE_DIR/bootstrap.lock"
LEGACY_PID_FILE="$STATE_DIR/setup.pid"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
PKG_LOG="$STATE_DIR/package-manager.log"
CURRENT_STAGE="고속 설치 시작"
CURRENT_PCT=1
CURRENT_ETA=300
OWN_LOCK=0
HEARTBEAT_LOOP_PID=""
mkdir -p "$STATE_DIR" "$CACHE_DIR"

log() {
  printf '[deskTAB] %s\n' "$*"
}

write_heartbeat() {
  local tmp="$HEARTBEAT_FILE.tmp.$$"
  printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$$" "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

heartbeat_loop() {
  set +e
  while true; do
    write_heartbeat
    sleep 2
  done
}

broadcast_progress() {
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$1" --el eta "$2" --es stage "$3" >/dev/null 2>&1 || true
}

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_PCT="$pct"
  CURRENT_ETA="$eta"
  CURRENT_STAGE="$*"
  log "$pct% · $CURRENT_STAGE"
  write_heartbeat
  broadcast_progress "$pct" "$eta" "$CURRENT_STAGE"
}

failed() {
  local code=$?
  local line="${BASH_LINENO[0]:-?}"
  set +e
  CURRENT_PCT=-1
  CURRENT_ETA=0
  CURRENT_STAGE="실패: $CURRENT_STAGE · line $line · exit $code"
  log "오류 · line $line · exit $code · $CURRENT_STAGE"
  write_heartbeat
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "$CURRENT_STAGE" >/dev/null 2>&1
  exit "$code"
}

cleanup() {
  set +e
  if [ -n "$HEARTBEAT_LOOP_PID" ]; then
    kill "$HEARTBEAT_LOOP_PID" >/dev/null 2>&1 || true
  fi
  if [ "$OWN_LOCK" = "1" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  if [ -f "$LEGACY_PID_FILE" ] && [ "$(cat "$LEGACY_PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$LEGACY_PID_FILE"
  fi
}

ps_table() {
  ps -A -o PID=,PPID=,ARGS= 2>/dev/null || /system/bin/ps -A -o PID=,PPID=,ARGS= 2>/dev/null || true
}

kill_tree() {
  local parent="$1" child
  while read -r child; do
    [ -n "$child" ] || continue
    kill_tree "$child"
  done < <(ps_table | awk -v p="$parent" '$2==p {print $1}')
  kill -TERM "$parent" >/dev/null 2>&1 || true
}

cleanup_stale_desktab_pkg_processes() {
  local pid ppid args
  while read -r pid ppid args; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = "$$" ] && continue
    [ -n "$HEARTBEAT_LOOP_PID" ] && [ "$pid" = "$HEARTBEAT_LOOP_PID" ] && continue
    case "$args" in
      *"apt-get update -o Acquire::Languages=none -o Acquire::Retries=3"*|\
      *"apt-get install -y termux-x11-nightly proot-distro pulseaudio"*|\
      *"apt-get install -y x11-repo"*)
        log "이전 deskTAB 패키지 작업 정리: PID $pid"
        kill_tree "$pid"
        ;;
    esac
  done < <(ps_table)
}

cleanup_legacy_desktab_processes() {
  local pid ppid args
  local found=0
  # 이 함수는 현재 heartbeat loop를 시작하기 전에 한 번만 호출한다.
  while read -r pid ppid args; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *desktab-bootstrap.sh*)
        log "이전 deskTAB 설치 프로세스 정리: PID $pid"
        kill_tree "$pid"
        found=1
        ;;
    esac
  done < <(ps_table)

  [ "$found" = "0" ] || sleep 2
  cleanup_stale_desktab_pkg_processes
  sleep 1
  rm -f "$LEGACY_PID_FILE" >/dev/null 2>&1 || true
}

acquire_singleton_lock() {
  local owner
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    OWN_LOCK=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" >/dev/null 2>&1; then
    log "이미 deskTAB 설치가 실행 중입니다 (PID $owner). 두 번째 설치는 시작하지 않습니다."
    broadcast_progress 2 300 "기존 deskTAB 설치가 이미 실행 중 · 중복 실행 차단"
    return 1
  fi

  log "죽은 설치 lock을 복구합니다."
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  OWN_LOCK=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  return 0
}

run_pkg() {
  local label="$1"; shift
  local attempt=0 code
  while true; do
    attempt=$((attempt + 1))
    : > "$PKG_LOG"
    set +e
    "$@" 2>&1 | tee "$PKG_LOG"
    code=${PIPESTATUS[0]}
    set -e
    if [ "$code" -eq 0 ]; then
      return 0
    fi
    if grep -qiE 'Could not get lock|Unable to acquire.*lock|frontend lock.*locked|dpkg frontend lock was locked' "$PKG_LOG"; then
      CURRENT_STAGE="$label · 다른 패키지 작업 종료 대기 (${attempt}/45)"
      CURRENT_ETA=$((300 - attempt * 2))
      [ "$CURRENT_ETA" -lt 30 ] && CURRENT_ETA=30
      log "$CURRENT_STAGE"
      write_heartbeat
      broadcast_progress "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE"
      if [ "$attempt" -eq 5 ]; then
        cleanup_stale_desktab_pkg_processes
      fi
      if [ "$attempt" -lt 45 ]; then
        sleep 2
        continue
      fi
    fi
    return "$code"
  done
}

log "=========================================="
log "deskTAB Chrome Linux bootstrap v6 시작"
log "HOME=$HOME"
log "PREFIX=${PREFIX:-<unset>}"
log "ARCH=$(uname -m)"
log "=========================================="

if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "Termux PREFIX 환경이 없습니다." >&2
  exit 30
fi

if ! acquire_singleton_lock; then
  exit 0
fi
trap failed ERR
trap cleanup EXIT
CURRENT_PCT=2
CURRENT_ETA=290
CURRENT_STAGE="이전 deskTAB 작업 정리 및 패키지 잠금 복구"
write_heartbeat
broadcast_progress "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE"

# heartbeat 보조 프로세스를 만들기 전에 v5 이하의 남은 프로세스를 정리한다.
cleanup_legacy_desktab_processes
heartbeat_loop &
HEARTBEAT_LOOP_PID=$!

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  progress 1 0 "현재 고속 이미지가 지원하지 않는 ABI: $ARCH"
  echo "Fast runtime currently requires ARM64/aarch64." >&2
  exit 41
fi

progress 2 285 "Termux 로컬 bootstrap 실행 확인 · 중복 실행 잠금 완료"

if command -v dpkg >/dev/null 2>&1; then
  run_pkg "dpkg 복구" dpkg --configure -a
fi

progress 3 275 "Termux 저장소 확인"
run_pkg "Termux 저장소 확인" apt-get update -o Acquire::Languages=none -o Acquire::Retries=3

if ! apt-cache show termux-x11-nightly >/dev/null 2>&1; then
  progress 5 265 "공식 Termux X11 저장소 추가"
  run_pkg "X11 저장소 설치" apt-get install -y x11-repo
  run_pkg "X11 저장소 갱신" apt-get update -o Acquire::Languages=none -o Acquire::Retries=3
fi

progress 7 250 "X11 · PRoot · 오디오 최소 구성 설치"
run_pkg "X11 · PRoot · 오디오 설치" apt-get install -y termux-x11-nightly proot-distro pulseaudio curl xz-utils tar coreutils procps

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
printf '%s\n' '6' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
log "설정이 완료되었습니다. deskTAB Chrome 앱으로 돌아가 Desktop Chrome 실행을 누르세요."
