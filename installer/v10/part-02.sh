        exit 0
      fi
    done
    sleep 1
  done
  rm -f "$tmp"
  exit 1
)

download_part() (
  trap - ERR
  set +e
  set +E
  local p="$1" expected_size="$2" expected_sha="$3" out="$CACHE_DIR/$1" partial="$CACHE_DIR/.$1.partial" attempt url
  if verify_part "$out" "$expected_size" "$expected_sha"; then exit 0; fi
  rm -f "$out" "$partial"
  for attempt in $(seq 1 12); do
    rm -f "$partial"
    if [ $((attempt % 2)) -eq 1 ]; then url="$RUNTIME_BASE/$p"; else url="$RUNTIME_BASE_ALT/$p"; fi
    if curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --speed-time 30 --speed-limit 1024 --max-time 600 \
      -H 'Cache-Control: no-cache' "$url" -o "$partial" \
      && verify_part "$partial" "$expected_size" "$expected_sha"; then
      mv -f "$partial" "$out"
      exit 0
    fi
    rm -f "$partial"
    sleep 1
  done
  exit 1
)

free_bytes() {
  df -Pk "$PREFIX" 2>/dev/null | awk 'NR==2 {printf "%.0f\n", $4*1024}'
}

remove_tree_monitored() {
  local path="$1" label="$2" pid start now elapsed
  [ -e "$path" ] || return 0
  rm -rf "$path" &
  pid=$!
  start="$(date +%s)"
  while kill -0 "$pid" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$((now - start))
    progress "$CURRENT_PCT" 0 "$label · ${elapsed}초"
    sleep 1
  done
  wait "$pid"
}

log "=========================================="
log "deskTAB Chrome Linux bootstrap v10 시작"
log "HOME=$HOME"
log "PREFIX=${PREFIX:-<unset>}"
log "ARCH=$(uname -m)"
log "=========================================="

if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "Termux PREFIX 환경이 없습니다." >&2
  exit 30
fi
if [ "$(uname -m)" != aarch64 ]; then
  progress 1 0 "현재 고속 이미지가 지원하지 않는 ABI: $(uname -m)"
  exit 41
fi

# v10 intentionally supersedes any previous v9 extractor that can sit at 82% for a long time.
progress 1 360 "이전 설치 프로세스 안전 종료"
cleanup_previous_installer
# A killed v9 extraction can leave multiple gigabytes in .ubuntu.new.*. Remove it
# before downloading the new runtime, otherwise the zstd download itself can run out of space.
progress 1 0 "이전 82% 미완료 rootfs 선제 정리"
LEGACY_STALE_PARENT="$PREFIX/var/lib/proot-distro/installed-rootfs"
MODERN_STALE_PARENT="$PREFIX/var/lib/proot-distro/containers/ubuntu"
while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 xz 임시 rootfs 삭제"; done < <(find "$LEGACY_STALE_PARENT" -maxdepth 1 -type d -name '.ubuntu.new.*' -print0 2>/dev/null)
while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 zstd 임시 rootfs 삭제"; done < <(find "$MODERN_STALE_PARENT" -maxdepth 1 -type d -name '.rootfs.new.*' -print0 2>/dev/null)
acquire_lock
trap failed ERR
trap cleanup EXIT
heartbeat_loop &
HEARTBEAT_LOOP_PID=$!

progress 2 345 "Termux 패키지 상태 확인"
if command -v dpkg >/dev/null 2>&1 && [ -n "$(dpkg --audit 2>/dev/null || true)" ]; then
  run_pkg "중단된 dpkg 구성 복구" dpkg --configure -a
fi
if find "$PREFIX/var/lib/apt/lists" -type f -mmin -360 2>/dev/null | grep -q .; then
  progress 4 330 "Termux 패키지 목록 최신 · update 생략"
else
  progress 3 340 "Termux 저장소 갱신"
  run_pkg "Termux 저장소 갱신" apt-get update -o Acquire::Languages=none -o Acquire::Retries=3 -o Dpkg::Use-Pty=0
fi
if ! apt-cache show termux-x11-nightly >/dev/null 2>&1; then
  progress 5 320 "공식 Termux X11 저장소 추가"
  run_pkg "X11 저장소 설치" apt-get install -y -o Dpkg::Use-Pty=0 x11-repo
  run_pkg "X11 저장소 갱신" apt-get update -o Acquire::Languages=none -o Acquire::Retries=3 -o Dpkg::Use-Pty=0
fi
install_component 7 300 "Termux:X11 런타임 확인" termux-x11-nightly
install_component 8 285 "PRoot 환경 확인" proot-distro
install_component 9 270 "PulseAudio 확인" pulseaudio
install_component 10 255 "고속 압축·검증 도구 확인" curl zstd tar coreutils procps

progress 11 245 "Termux:X11 :1 서버 준비"
export XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
if ! pgrep -f 'termux-x11 :1' >/dev/null 2>&1; then
  termux-x11 :1 >"$STATE_DIR/x11.log" 2>&1 &
  sleep 2
fi

progress 12 235 "최신 zstd Linux 이미지 버전 고정"
RUNTIME_COMMIT="$(resolve_runtime_commit)" || {
  progress 12 0 "runtime-image 버전 확인 실패 · 네트워크 확인"
  exit 42
}
printf '%s' "$RUNTIME_COMMIT" | grep -qE '^[0-9a-f]{40}$' || exit 42
RUNTIME_BASE="https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/$RUNTIME_COMMIT/runtime"
RUNTIME_BASE_ALT="https://github.com/KKomaProgrammer/deskTAB-chrome/raw/$RUNTIME_COMMIT/runtime"
CACHE_DIR="$CACHE_ROOT/$RUNTIME_COMMIT"
mkdir -p "$CACHE_DIR"
MANIFEST="$CACHE_DIR/manifest.txt"

if ! fetch_manifest; then
  progress 12 0 "zstd Linux 이미지 manifest 완전성 확인 실패 · 구형 xz 런타임은 사용하지 않음"
  exit 42
fi
TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2; exit}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2; exit}' "$MANIFEST")"
ROOTFS_TAR_SIZE="$(awk '$1=="ROOTFS_TAR_SIZE"{print $2; exit}' "$MANIFEST")"
ROOTFS_FILE_BYTES="$(awk '$1=="ROOTFS_FILE_BYTES"{print $2; exit}' "$MANIFEST")"
mapfile -t PART_NAMES < <(awk '$1=="PART"{print $2}' "$MANIFEST")
mapfile -t PART_SIZES < <(awk '$1=="PART"{print $3}' "$MANIFEST")
mapfile -t PART_SHAS < <(awk '$1=="PART"{print $4}' "$MANIFEST")
PART_COUNT="${#PART_NAMES[@]}"
log "zstd runtime: $RUNTIME_COMMIT · $PART_COUNT parts · $TOTAL_SIZE bytes"

# The largest old cache is no longer allowed to pin v10 to an xz runtime. Remove all
# other commit caches so a previous 82%-stalled extraction cannot consume gigabytes.
progress 13 225 "구형 xz/중단 캐시 정리"
for d in "$CACHE_ROOT"/*; do
  [ -d "$d" ] || continue
  [ "$d" = "$CACHE_DIR" ] && continue
  rm -rf "$d"
done
rm -f "$CACHE_DIR"/.runtime-arm64.part-*.partial "$CACHE_DIR"/.runtime-arm64.tar.*.assembling 2>/dev/null || true

progress 14 215 "Linux zstd 이미지 병렬 다운로드 시작"
DOWNLOAD_PIDS=()
START_TS="$(date +%s)"
update_download_progress() {
  local done=0 j f partial size expected now elapsed pct eta
