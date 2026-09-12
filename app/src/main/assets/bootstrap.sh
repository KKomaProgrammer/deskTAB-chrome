#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
CACHE_DIR="$STATE_DIR/runtime-cache"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/runtime-image/runtime"
LOCK_DIR="$STATE_DIR/bootstrap.lock"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
HEARTBEAT_STATE_FILE="$STATE_DIR/heartbeat-state"
PKG_LOG="$STATE_DIR/package-manager.log"
CURRENT_STAGE="고속 설치 시작"
CURRENT_PCT=1
CURRENT_ETA=300
OWN_LOCK=0
HEARTBEAT_LOOP_PID=""
BOOTSTRAP_PID="$$"
mkdir -p "$STATE_DIR" "$CACHE_DIR"

log() {
  printf '[deskTAB] %s\n' "$*"
}

write_state() {
  local tmp="$HEARTBEAT_STATE_FILE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_STATE_FILE"
}

write_heartbeat() {
  local state tmp
  state="$(cat "$HEARTBEAT_STATE_FILE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$HEARTBEAT_FILE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$BOOTSTRAP_PID" "$state" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

publish_state() {
  write_state
  write_heartbeat
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
  publish_state
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
  publish_state
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "$CURRENT_STAGE" >/dev/null 2>&1 || true
  exit "$code"
}

cleanup() {
  set +e
  [ -n "$HEARTBEAT_LOOP_PID" ] && kill "$HEARTBEAT_LOOP_PID" >/dev/null 2>&1 || true
  if [ "$OWN_LOCK" = "1" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
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

cleanup_legacy_desktab_processes() {
  local pid ppid args
  while read -r pid ppid args; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *desktab-bootstrap.sh*)
        log "이전 deskTAB 설치 프로세스 정리: PID $pid"
        kill_tree "$pid"
        ;;
      *"apt-get update -o Acquire::Languages=none"*|*"apt-get install -y termux-x11-nightly proot-distro pulseaudio"*)
        log "이전 deskTAB 패키지 작업 정리: PID $pid"
        kill_tree "$pid"
        ;;
    esac
  done < <(ps_table)
  sleep 1
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
    log "이미 deskTAB 설치가 실행 중입니다 (PID $owner). 중복 실행하지 않습니다."
    return 1
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  OWN_LOCK=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

run_pkg() {
  local label="$1"; shift
  local attempt=0 code start now elapsed last_sig sig last_change line base_eta pid idle
  while true; do
    attempt=$((attempt + 1))
    : > "$PKG_LOG"
    start="$(date +%s)"
    last_change="$start"
    last_sig=""
    base_eta="$CURRENT_ETA"

    set +e
    env DEBIAN_FRONTEND=noninteractive "$@" >"$PKG_LOG" 2>&1 &
    pid=$!
    set -e

    while kill -0 "$pid" >/dev/null 2>&1; do
      now="$(date +%s)"
      elapsed=$((now - start))
      sig="$(stat -c '%s:%Y' "$PKG_LOG" 2>/dev/null || echo 0:0)"
      if [ "$sig" != "$last_sig" ]; then
        last_sig="$sig"
        last_change="$now"
      fi
      idle=$((now - last_change))
      line="$(tail -n 1 "$PKG_LOG" 2>/dev/null | tr '\r\n|' '   ' | cut -c1-100)"
      if [ "$idle" -ge 60 ]; then
        CURRENT_STAGE="$label · 출력 없음 ${idle}초 · 패키지 설정/서버 응답 대기"
        CURRENT_ETA=0
      elif [ -n "$line" ]; then
        CURRENT_STAGE="$label · $line"
        CURRENT_ETA=$((base_eta - elapsed))
        [ "$CURRENT_ETA" -lt 20 ] && CURRENT_ETA=20
      else
        CURRENT_STAGE="$label · 처리 중 ${elapsed}초"
        CURRENT_ETA=$((base_eta - elapsed))
        [ "$CURRENT_ETA" -lt 20 ] && CURRENT_ETA=20
      fi
      publish_state
      broadcast_progress "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE"
      sleep 2
    done

    set +e
    wait "$pid"
    code=$?
    set -e
    cat "$PKG_LOG" 2>/dev/null || true
    if [ "$code" -eq 0 ]; then
      return 0
    fi

    if grep -qiE 'Could not get lock|Unable to acquire.*lock|frontend lock.*locked|dpkg frontend lock was locked' "$PKG_LOG"; then
      if [ "$attempt" -lt 30 ]; then
        CURRENT_STAGE="$label · dpkg 잠금 해제 대기 (${attempt}/30)"
        CURRENT_ETA=0
        publish_state
        broadcast_progress "$CURRENT_PCT" 0 "$CURRENT_STAGE"
        sleep 2
        continue
      fi
    fi
    return "$code"
  done
}

install_component() {
  local pct="$1" eta="$2" label="$3"; shift 3
  local missing=() p
  for p in "$@"; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    progress "$pct" "$eta" "$label · 이미 설치됨, 건너뜀"
    return 0
  fi
  progress "$pct" "$eta" "$label · ${missing[*]}"
  run_pkg "$label" apt-get install -y -o Dpkg::Use-Pty=0 -o Acquire::Languages=none -o Acquire::Retries=2 "${missing[@]}"
}

log "=========================================="
log "deskTAB Chrome Linux bootstrap v6.2 시작"
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
CURRENT_ETA=280
CURRENT_STAGE="이전 deskTAB 작업 정리"
publish_state
broadcast_progress "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE"
cleanup_legacy_desktab_processes
heartbeat_loop &
HEARTBEAT_LOOP_PID=$!

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  progress 1 0 "현재 고속 이미지가 지원하지 않는 ABI: $ARCH"
  exit 41
fi

progress 2 275 "Termux bootstrap 실행 확인"
if command -v dpkg >/dev/null 2>&1 && [ -n "$(dpkg --audit 2>/dev/null || true)" ]; then
  run_pkg "중단된 dpkg 구성 복구" dpkg --configure -a
fi

# 패키지 목록이 최근 6시간 안에 갱신됐다면 매번 apt update를 반복하지 않는다.
if find "$PREFIX/var/lib/apt/lists" -type f -mmin -360 2>/dev/null | grep -q .; then
  progress 4 260 "Termux 패키지 목록 최신 · update 생략"
else
  progress 3 270 "Termux 저장소 갱신"
  run_pkg "Termux 저장소 갱신" apt-get update -o Acquire::Languages=none -o Acquire::Retries=2 -o Dpkg::Use-Pty=0
fi

if ! apt-cache show termux-x11-nightly >/dev/null 2>&1; then
  progress 5 250 "공식 Termux X11 저장소 추가"
  run_pkg "X11 저장소 설치" apt-get install -y -o Dpkg::Use-Pty=0 x11-repo
  run_pkg "X11 저장소 갱신" apt-get update -o Acquire::Languages=none -o Acquire::Retries=2 -o Dpkg::Use-Pty=0
fi

# 이전 버전은 이 전체 묶음을 7% 한 단계로 처리했다. 이제 실제 구성요소별로
# 건너뛰기/설치 상태를 표시해 어느 단계가 느린지 즉시 알 수 있게 한다.
install_component 7 235 "Termux:X11 런타임 설치" termux-x11-nightly
install_component 8 220 "PRoot 환경 설치" proot-distro
install_component 9 205 "PulseAudio 설치" pulseaudio
install_component 10 190 "압축·다운로드 도구 확인" curl xz-utils tar coreutils procps

progress 11 180 "Termux:X11 :1 서버 시작"
export XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
if ! pgrep -f 'termux-x11 :1' >/dev/null 2>&1; then
  termux-x11 :1 >"$STATE_DIR/x11.log" 2>&1 &
  sleep 2
fi

progress 12 170 "사전 구성 Linux 이미지 정보 확인"
MANIFEST="$CACHE_DIR/manifest.txt"
curl -fL --retry 5 --retry-delay 1 --connect-timeout 10 "$RUNTIME_BASE/manifest.txt" -o "$MANIFEST"
TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2}' "$MANIFEST")"
FORMAT="$(awk '$1=="FORMAT"{print $2}' "$MANIFEST")"
PART_COUNT="$(awk '$1=="PART"{n++} END{print n+0}' "$MANIFEST")"
if [ -z "$TOTAL_SIZE" ] || [ "$TOTAL_SIZE" -le 0 ] || [ "$PART_COUNT" -le 0 ]; then
  echo "Invalid fast-runtime manifest" >&2
  exit 42
fi
[ "$FORMAT" = "xz" ] || { echo "Unsupported runtime format: $FORMAT" >&2; exit 45; }

progress 14 160 "Linux 이미지 병렬 다운로드 시작 ($PART_COUNT개 조각)"
export CACHE_DIR RUNTIME_BASE

download_part() {
  local p="$1" out="$CACHE_DIR/$1" url="$RUNTIME_BASE/$1"
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
    [ -f "$f" ] && DONE=$((DONE + $(stat -c %s "$f" 2>/dev/null || echo 0)))
  done < <(awk '$1=="PART"{print}' "$MANIFEST")
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS)); [ "$ELAPSED" -lt 1 ] && ELAPSED=1
  PCT=$((14 + DONE * 64 / TOTAL_SIZE)); [ "$PCT" -gt 78 ] && PCT=78
  if [ "$DONE" -gt 1048576 ]; then
    ETA=$(((TOTAL_SIZE - DONE) * ELAPSED / DONE + 45))
  else
    ETA=160
  fi
  progress "$PCT" "$ETA" "Linux 이미지 다운로드 $((DONE / 1048576))/$((TOTAL_SIZE / 1048576))MB"
  sleep 1
done
wait

progress 79 45 "다운로드 무결성 검사"
while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  actual_size=$(stat -c %s "$CACHE_DIR/$part")
  [ "$actual_size" = "$size" ] || { echo "Size mismatch: $part" >&2; exit 43; }
  echo "$sha  $CACHE_DIR/$part" | sha256sum -c - >/dev/null
done < "$MANIFEST"
CALC_SHA=$(while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") | sha256sum | awk '{print $1}')
[ "$CALC_SHA" = "$ARCHIVE_SHA" ] || { echo "Archive checksum mismatch" >&2; exit 44; }

progress 82 38 "Ubuntu + XFCE + Chrome 이미지 고속 해제"
LEGACY_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
MODERN_CONTAINER="$PREFIX/var/lib/proot-distro/containers/ubuntu"
rm -rf "$LEGACY_ROOT" "$MODERN_CONTAINER"
mkdir -p "$LEGACY_ROOT"
while read -r _ part _ _; do cat "$CACHE_DIR/$part"; done < <(awk '$1=="PART"{print}' "$MANIFEST") | xz -dc | tar -xpf - -C "$LEGACY_ROOT"

progress 94 16 "Linux 네트워크 및 PRoot 확인"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'

progress 97 7 "원클릭 Chrome 실행 환경 구성"
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
