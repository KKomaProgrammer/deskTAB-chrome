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
log "deskTAB Chrome Linux bootstrap v7.0 시작"
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

progress 12 170 "사전 구성 Linux 이미지 버전 고정"
CACHE_ROOT="$CACHE_DIR"
FALLBACK_RUNTIME_COMMIT="0539b88f60bcde8f552572180a2632857b64b71c"
RUNTIME_META="$STATE_DIR/runtime-branch.json"

resolve_runtime_commit() (
  trap - ERR
  set +e
  local attempt code sha tmp="$RUNTIME_META.tmp.$$"
  for attempt in 1 2 3; do
    rm -f "$tmp"
    curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      'https://api.github.com/repos/KKomaProgrammer/deskTAB-chrome/branches/runtime-image' -o "$tmp"
    code=$?
    if [ "$code" -eq 0 ] && [ -s "$tmp" ]; then
      sha="$(grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' "$tmp" 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -n1)"
      if printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
        mv -f "$tmp" "$RUNTIME_META"
        printf '%s\n' "$sha"
        exit 0
      fi
    fi
    sleep 1
  done
  rm -f "$tmp"
  printf '%s\n' "$FALLBACK_RUNTIME_COMMIT"
  exit 0
)

RUNTIME_COMMIT="$(resolve_runtime_commit)"
if ! printf '%s' "$RUNTIME_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
  progress 12 0 "Linux 이미지 버전 확인 실패"
  exit 42
fi
log "고정 런타임 커밋: $RUNTIME_COMMIT"
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$RUNTIME_COMMIT/runtime"
RUNTIME_BASE_ALT="https://github.com/KKomaProgrammer/deskTAB-chrome/raw/$RUNTIME_COMMIT/runtime"
CACHE_DIR="$CACHE_ROOT/$RUNTIME_COMMIT"
mkdir -p "$CACHE_DIR"
MANIFEST="$CACHE_DIR/manifest.txt"

fetch_manifest() (
  trap - ERR
  set +e
  local tmp="$MANIFEST.tmp.$$" base code
  rm -f "$tmp"
  for base in "$RUNTIME_BASE" "$RUNTIME_BASE_ALT"; do
    curl -fL --retry 5 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 60 \
      "$base/manifest.txt" -o "$tmp"
    code=$?
    if [ "$code" -eq 0 ] && grep -q '^ARCH arm64$' "$tmp" && grep -q '^FORMAT xz$' "$tmp"; then
      mv -f "$tmp" "$MANIFEST"
      exit 0
    fi
    rm -f "$tmp"
  done
  exit 1
)

if ! fetch_manifest; then
  progress 12 0 "사전 구성 Linux 이미지 manifest 다운로드 실패"
  exit 42
fi

TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2}' "$MANIFEST")"
FORMAT="$(awk '$1=="FORMAT"{print $2}' "$MANIFEST")"
PART_COUNT="$(awk '$1=="PART"{n++} END{print n+0}' "$MANIFEST")"
if ! printf '%s' "$TOTAL_SIZE" | grep -qE '^[0-9]+$' || [ "$TOTAL_SIZE" -le 0 ] || [ "$PART_COUNT" -le 0 ]; then
  progress 12 0 "Linux 이미지 manifest 형식 오류"
  exit 42
fi
if ! printf '%s' "$ARCHIVE_SHA" | grep -qE '^[0-9a-f]{64}$'; then
  progress 12 0 "Linux 이미지 전체 SHA 정보 오류"
  exit 42
fi
[ "$FORMAT" = "xz" ] || { progress 12 0 "지원하지 않는 Linux 이미지 형식: $FORMAT"; exit 45; }

verify_part_file() {
  local file="$1" expected_size="$2" expected_sha="$3"
  local actual_size actual_line actual_sha
  [ -f "$file" ] || return 1
  actual_size="$(stat -c %s "$file" 2>/dev/null || printf '0')"
  [ "$actual_size" = "$expected_size" ] || return 1
  actual_line="$(sha256sum "$file" 2>/dev/null)" || return 1
  actual_sha="${actual_line%% *}"
  [ "$actual_sha" = "$expected_sha" ]
}

progress 13 165 "기존 Linux 이미지 조각 검증"
while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  target="$CACHE_DIR/$part"
  legacy="$CACHE_ROOT/$part"
  if verify_part_file "$target" "$size" "$sha"; then
    continue
  fi
  rm -f "$target"
  if verify_part_file "$legacy" "$size" "$sha"; then
    mv -f "$legacy" "$target"
  else
    rm -f "$legacy"
  fi
done < "$MANIFEST"
rm -f "$CACHE_ROOT"/.runtime-arm64.part-*.partial "$CACHE_ROOT"/.runtime-arm64.part-*.repair.* 2>/dev/null || true

download_part() (
  trap - ERR
  set +e
  set +E
  local p="$1" expected_size="$2" expected_sha="$3"
  local out="$CACHE_DIR/$p" partial="$CACHE_DIR/.${p}.partial"
  local attempt actual url code

  if verify_part_file "$out" "$expected_size" "$expected_sha"; then
    rm -f "$partial"
    exit 0
  fi
  rm -f "$out"

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    actual=0
    if [ -f "$partial" ]; then
      actual="$(stat -c %s "$partial" 2>/dev/null || printf '0')"
      if [ "$actual" -ge "$expected_size" ]; then
        rm -f "$partial"
        actual=0
      fi
    fi

    if [ $((attempt % 2)) -eq 1 ]; then
      url="$RUNTIME_BASE/$p"
    else
      url="$RUNTIME_BASE_ALT/$p"
    fi

    if [ -f "$partial" ] && [ "$actual" -gt 0 ]; then
      curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 \
        --speed-time 30 --speed-limit 1024 --max-time 600 -C - "$url" -o "$partial"
      code=$?
    else
      curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 \
        --speed-time 30 --speed-limit 1024 --max-time 600 "$url" -o "$partial"
      code=$?
    fi

    if [ "$code" -eq 0 ] && verify_part_file "$partial" "$expected_size" "$expected_sha"; then
      mv -f "$partial" "$out"
      sync "$out" >/dev/null 2>&1 || true
      exit 0
    fi

    actual="$(stat -c %s "$partial" 2>/dev/null || printf '0')"
    if [ "$actual" -ge "$expected_size" ] || [ $((attempt % 3)) -eq 0 ]; then
      rm -f "$partial"
    fi
    sleep 1
  done

  rm -f "$partial"
  exit 1
)

progress 14 160 "Linux 이미지 병렬 다운로드 시작 ($PART_COUNT개 조각)"
export CACHE_DIR RUNTIME_BASE RUNTIME_BASE_ALT
DOWNLOAD_PIDS=()
DOWNLOAD_PARTS=()
DOWNLOAD_BATCH_FAILED=0
START_TS="$(date +%s)"

update_download_progress() {
  local done=0 f size now elapsed pct eta
  while read -r kind part expected sha; do
    [ "$kind" = "PART" ] || continue
    f="$CACHE_DIR/$part"
    partial="$CACHE_DIR/.${part}.partial"
    if [ -f "$f" ]; then
      size="$(stat -c %s "$f" 2>/dev/null || printf '0')"
    elif [ -f "$partial" ]; then
      size="$(stat -c %s "$partial" 2>/dev/null || printf '0')"
    else
      size=0
    fi
    [ "$size" -gt "$expected" ] && size="$expected"
    done=$((done + size))
  done < "$MANIFEST"
  now="$(date +%s)"
  elapsed=$((now - START_TS)); [ "$elapsed" -lt 1 ] && elapsed=1
  pct=$((14 + done * 64 / TOTAL_SIZE)); [ "$pct" -gt 78 ] && pct=78
  if [ "$done" -ge "$TOTAL_SIZE" ]; then
    eta=15
  elif [ "$done" -gt 1048576 ]; then
    eta=$(((TOTAL_SIZE - done) * elapsed / done + 30))
  else
    eta=160
  fi
  progress "$pct" "$eta" "Linux 이미지 다운로드·검증 $((done / 1048576))/$((TOTAL_SIZE / 1048576))MB"
}

wait_download_batch() {
  local alive pid rc
  while true; do
    alive=0
    for pid in "${DOWNLOAD_PIDS[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        alive=1
        break
      fi
    done
    update_download_progress
    [ "$alive" -eq 0 ] && break
    sleep 1
  done
  for pid in "${DOWNLOAD_PIDS[@]}"; do
    if wait "$pid"; then
      rc=0
    else
      rc=$?
      DOWNLOAD_BATCH_FAILED=1
      log "다운로드 작업 PID $pid 1차 시도 실패(code=$rc) · 최종 확인에서 다시 시도합니다."
    fi
  done
  DOWNLOAD_PIDS=()
  DOWNLOAD_PARTS=()
  return 0
}

while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  if verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
    continue
  fi
  download_part "$part" "$size" "$sha" &
  DOWNLOAD_PIDS+=("$!")
  DOWNLOAD_PARTS+=("$part")
  if [ "${#DOWNLOAD_PIDS[@]}" -ge 6 ]; then
    wait_download_batch
  fi
done < "$MANIFEST"

if [ "${#DOWNLOAD_PIDS[@]}" -gt 0 ]; then
  wait_download_batch
fi
update_download_progress

while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  if verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
    continue
  fi
  progress 78 30 "Linux 이미지 미완료 조각 재다운로드 · $part"
  if download_part "$part" "$size" "$sha" && verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
    continue
  fi
  progress 78 0 "Linux 이미지 다운로드 실패 · $part 검증 다운로드 반복 실패"
  exit 43
done < "$MANIFEST"

progress 79 30 "모든 조각 검증 완료 · 전체 이미지 SHA 확인"
PART_PATHS=()
while read -r kind part _ _; do
  [ "$kind" = "PART" ] || continue
  PART_PATHS+=("$CACHE_DIR/$part")
done < "$MANIFEST"

calculate_archive_sha() (
  trap - ERR
  set +e
  set +E
  set -o pipefail
  cat "$@" | sha256sum
)

if HASH_LINE="$(calculate_archive_sha "${PART_PATHS[@]}")"; then
  CALC_SHA="${HASH_LINE%% *}"
else
  progress 79 0 "전체 Linux 이미지 SHA 계산 실패"
  exit 44
fi
if [ "$CALC_SHA" != "$ARCHIVE_SHA" ]; then
  progress 79 0 "전체 Linux 이미지 SHA 불일치 · manifest/runtime 버전 불일치"
  exit 44
fi

validate_xz_archive() (
  trap - ERR
  set +e
  set +E
  set -o pipefail
  cat "$@" | xz -t
)

progress 80 24 "Linux 이미지 XZ 구조 검사"
if ! validate_xz_archive "${PART_PATHS[@]}"; then
  progress 80 0 "Linux 이미지 XZ 구조 손상"
  exit 45
fi

progress 82 38 "Ubuntu + XFCE + Chrome 이미지 고속 해제"
LEGACY_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
MODERN_CONTAINER="$PREFIX/var/lib/proot-distro/containers/ubuntu"
NEW_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/.ubuntu.new.$$"
BACKUP_LEGACY="$PREFIX/var/lib/proot-distro/installed-rootfs/.ubuntu.backup.$$"
BACKUP_MODERN="$PREFIX/var/lib/proot-distro/containers/.ubuntu.backup.$$"
mkdir -p "$(dirname "$LEGACY_ROOT")" "$(dirname "$MODERN_CONTAINER")"
rm -rf "$NEW_ROOT" "$BACKUP_LEGACY" "$BACKUP_MODERN"
mkdir -p "$NEW_ROOT"

extract_runtime() (
  trap - ERR
  set +e
  set +E
  set -o pipefail
  local dest="$1"; shift
  cat "$@" | xz -dc | tar -xpf - -C "$dest"
)

if ! extract_runtime "$NEW_ROOT" "${PART_PATHS[@]}"; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "Linux 이미지 압축 해제 실패 · 기존 환경 유지"
  exit 46
fi

# 네트워크 파일 구성도 새 rootfs에서 먼저 끝낸다. 여기서 실패해도 기존 환경은 untouched 상태다.
if ! mkdir -p "$NEW_ROOT/etc"; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "새 Linux 환경 준비 실패 · 기존 환경 유지"
  exit 46
fi
rm -f "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$NEW_ROOT/etc/hosts"

# 디렉터리 rename은 같은 Termux 파일시스템 안에서 원자적이다. 각 단계 실패 시 즉시 원상복구한다.
SWAP_OK=1
if [ -d "$LEGACY_ROOT" ] && ! mv "$LEGACY_ROOT" "$BACKUP_LEGACY"; then
  SWAP_OK=0
fi
if [ "$SWAP_OK" -eq 1 ] && [ -d "$MODERN_CONTAINER" ] && ! mv "$MODERN_CONTAINER" "$BACKUP_MODERN"; then
  [ -d "$BACKUP_LEGACY" ] && mv "$BACKUP_LEGACY" "$LEGACY_ROOT" || true
  SWAP_OK=0
fi
if [ "$SWAP_OK" -eq 1 ] && ! mv "$NEW_ROOT" "$LEGACY_ROOT"; then
  [ -d "$BACKUP_LEGACY" ] && mv "$BACKUP_LEGACY" "$LEGACY_ROOT" || true
  [ -d "$BACKUP_MODERN" ] && mv "$BACKUP_MODERN" "$MODERN_CONTAINER" || true
  SWAP_OK=0
fi
if [ "$SWAP_OK" -ne 1 ]; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "Linux 환경 교체 실패 · 기존 환경 복원 완료"
  exit 46
fi

progress 94 16 "Linux 네트워크 및 PRoot 확인"
if proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'; then
  rm -rf "$BACKUP_LEGACY" "$BACKUP_MODERN"
else
  rm -rf "$LEGACY_ROOT" "$MODERN_CONTAINER"
  [ -d "$BACKUP_LEGACY" ] && mv "$BACKUP_LEGACY" "$LEGACY_ROOT"
  [ -d "$BACKUP_MODERN" ] && mv "$BACKUP_MODERN" "$MODERN_CONTAINER"
  progress 94 0 "PRoot 첫 로그인 실패 · 기존 환경 복원 완료"
  exit 47
fi
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

rm -rf "$CACHE_ROOT"
mkdir -p "$CACHE_ROOT"
printf '%s\n' '7' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
log "설정이 완료되었습니다. deskTAB Chrome 앱으로 돌아가 Desktop Chrome 실행을 누르세요."
