  done
  now="$(date +%s)"; elapsed=$((now - START_TS)); [ "$elapsed" -lt 1 ] && elapsed=1
  pct=$((14 + done * 64 / TOTAL_SIZE)); [ "$pct" -gt 78 ] && pct=78
  if [ "$done" -gt 1048576 ] && [ "$done" -lt "$TOTAL_SIZE" ]; then eta=$(((TOTAL_SIZE-done)*elapsed/done + 35)); else eta=180; fi
  [ "$done" -ge "$TOTAL_SIZE" ] && eta=35
  progress "$pct" "$eta" "Linux zstd 이미지 다운로드·검증 $((done/1048576))/$((TOTAL_SIZE/1048576))MB"
}
wait_batch() {
  local alive pid
  while true; do
    alive=0
    for pid in "${DOWNLOAD_PIDS[@]}"; do if kill -0 "$pid" >/dev/null 2>&1; then alive=1; break; fi; done
    update_download_progress
    [ "$alive" -eq 0 ] && break
    sleep 1
  done
  for pid in "${DOWNLOAD_PIDS[@]}"; do wait "$pid" || true; done
  DOWNLOAD_PIDS=()
}
for ((i=0; i<PART_COUNT; i++)); do
  if verify_part "$CACHE_DIR/${PART_NAMES[$i]}" "${PART_SIZES[$i]}" "${PART_SHAS[$i]}"; then continue; fi
  download_part "${PART_NAMES[$i]}" "${PART_SIZES[$i]}" "${PART_SHAS[$i]}" &
  DOWNLOAD_PIDS+=("$!")
  [ "${#DOWNLOAD_PIDS[@]}" -ge 6 ] && wait_batch
done
[ "${#DOWNLOAD_PIDS[@]}" -gt 0 ] && wait_batch
update_download_progress
for ((i=0; i<PART_COUNT; i++)); do
  if ! verify_part "$CACHE_DIR/${PART_NAMES[$i]}" "${PART_SIZES[$i]}" "${PART_SHAS[$i]}"; then
    progress 78 45 "누락 조각 최종 재다운로드 · ${PART_NAMES[$i]}"
    download_part "${PART_NAMES[$i]}" "${PART_SIZES[$i]}" "${PART_SHAS[$i]}" || {
      progress 78 0 "Linux 이미지 조각 확보 실패 · ${PART_NAMES[$i]}"; exit 43; }
  fi
done

ARCHIVE_FILE="$CACHE_DIR/runtime-arm64.tar.zst"
ARCHIVE_TMP="$CACHE_DIR/.runtime-arm64.tar.zst.assembling"
if ! verify_archive "$ARCHIVE_FILE"; then
  rm -f "$ARCHIVE_FILE" "$ARCHIVE_TMP"
  : > "$ARCHIVE_TMP"
  ASSEMBLED=0
  for ((i=0; i<PART_COUNT; i++)); do
    p="$CACHE_DIR/${PART_NAMES[$i]}"
    verify_part "$p" "${PART_SIZES[$i]}" "${PART_SHAS[$i]}" || exit 43
    cat "$p" >> "$ARCHIVE_TMP" || { progress 79 0 "이미지 조립 쓰기 실패 · 저장공간 확인"; exit 44; }
    ASSEMBLED=$((ASSEMBLED + PART_SIZES[i]))
    actual="$(stat -c %s "$ARCHIVE_TMP")"
    [ "$actual" -eq "$ASSEMBLED" ] || { progress 79 0 "이미지 조립 크기 불일치"; exit 44; }
    pct=$((79 + ASSEMBLED * 2 / TOTAL_SIZE)); [ "$pct" -gt 81 ] && pct=81
    progress "$pct" 30 "zstd 이미지 조립 $((i+1))/$PART_COUNT · $((ASSEMBLED/1048576))MB"
  done
  [ "$ASSEMBLED" -eq "$TOTAL_SIZE" ] || exit 44
  calc="$(sha256sum "$ARCHIVE_TMP" | awk '{print $1}')"
  [ "$calc" = "$ARCHIVE_SHA" ] || { progress 81 0 "완성 zstd 이미지 SHA 불일치"; exit 44; }
  mv -f "$ARCHIVE_TMP" "$ARCHIVE_FILE"
fi
progress 81 25 "zstd 이미지 무결성 최종 검사"
verify_archive "$ARCHIVE_FILE" && zstd -t -q "$ARCHIVE_FILE" || { progress 81 0 "zstd 이미지 최종 검증 실패"; exit 45; }
for ((i=0; i<PART_COUNT; i++)); do rm -f "$CACHE_DIR/${PART_NAMES[$i]}"; done
rm -f "$CACHE_DIR"/.runtime-arm64.part-*.partial 2>/dev/null || true

LEGACY_PARENT="$PREFIX/var/lib/proot-distro/installed-rootfs"
LEGACY_ROOT="$LEGACY_PARENT/ubuntu"
CONTAINERS_PARENT="$PREFIX/var/lib/proot-distro/containers"
MODERN_CONTAINER="$CONTAINERS_PARENT/ubuntu"
MODERN_PARENT="$MODERN_CONTAINER"
MODERN_ROOT="$MODERN_CONTAINER/rootfs"
mkdir -p "$LEGACY_PARENT" "$CONTAINERS_PARENT"

# Recover an environment that an older installer may have moved to a backup immediately
# before Android/Termux killed the process. A backup is restored only when no active root
# exists, so an already-working installation is never overwritten.
if [ ! -d "$LEGACY_ROOT" ] && [ ! -d "$MODERN_ROOT" ]; then
  RECOVER_LEGACY="$(find "$LEGACY_PARENT" -maxdepth 1 -type d -name '.ubuntu.backup.*' -print 2>/dev/null | sort | tail -n1)"
  if [ -n "$RECOVER_LEGACY" ] && [ -d "$RECOVER_LEGACY" ]; then
    progress 82 90 "중단된 이전 설치의 Ubuntu 환경 복원"
    mv "$RECOVER_LEGACY" "$LEGACY_ROOT" || { progress 82 0 "기존 Ubuntu 백업 복원 실패"; exit 46; }
  else
    RECOVER_MODERN="$(find "$CONTAINERS_PARENT" -maxdepth 1 -type d -name '.ubuntu.backup.*' -print 2>/dev/null | sort | tail -n1)"
    if [ -n "$RECOVER_MODERN" ] && [ -d "$RECOVER_MODERN" ]; then
      progress 82 90 "중단된 이전 설치의 PRoot 컨테이너 복원"
      mv "$RECOVER_MODERN" "$MODERN_CONTAINER" || { progress 82 0 "기존 PRoot 컨테이너 백업 복원 실패"; exit 46; }
    fi
  fi
fi

# Recover v10-style rootfs-only backup if a swap was interrupted after the move.
if [ ! -d "$LEGACY_ROOT" ] && [ ! -d "$MODERN_ROOT" ] && [ -d "$MODERN_CONTAINER" ]; then
  RECOVER_ROOTFS="$(find "$MODERN_CONTAINER" -maxdepth 1 -type d -name '.rootfs.backup.*' -print 2>/dev/null | sort | tail -n1)"
  if [ -n "$RECOVER_ROOTFS" ] && [ -d "$RECOVER_ROOTFS" ]; then
    progress 82 90 "중단된 이전 설치의 rootfs 복원"
    mv "$RECOVER_ROOTFS" "$MODERN_ROOT" || { progress 82 0 "기존 rootfs 백업 복원 실패"; exit 46; }
  fi
fi

# Clean only installer-owned temporary directories. Never delete the active rootfs.
progress 82 90 "이전 미완료 해제 데이터 정리"
while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 미완료 rootfs 삭제"; done < <(find "$LEGACY_PARENT" -maxdepth 1 -type d -name '.ubuntu.new.*' -print0 2>/dev/null)
if [ -d "$LEGACY_ROOT" ]; then
  while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 백업 rootfs 정리"; done < <(find "$LEGACY_PARENT" -maxdepth 1 -type d -name '.ubuntu.backup.*' -print0 2>/dev/null)
fi

if [ -d "$MODERN_ROOT" ] && [ ! -d "$LEGACY_ROOT" ]; then
  ACTIVE_LAYOUT=modern
  ACTIVE_ROOT="$MODERN_ROOT"
  NEW_ROOT="$MODERN_PARENT/.rootfs.new.$$"
  BACKUP_ROOT="$MODERN_PARENT/.rootfs.backup.$$"
  while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 미완료 rootfs 삭제"; done < <(find "$MODERN_PARENT" -maxdepth 1 -type d -name '.rootfs.new.*' -print0 2>/dev/null)
  if [ -d "$ACTIVE_ROOT" ]; then
    while IFS= read -r -d '' stale; do remove_tree_monitored "$stale" "이전 백업 rootfs 정리"; done < <(find "$MODERN_PARENT" -maxdepth 1 -type d -name '.rootfs.backup.*' -print0 2>/dev/null)
  fi
else
  ACTIVE_LAYOUT=legacy
  ACTIVE_ROOT="$LEGACY_ROOT"
  NEW_ROOT="$LEGACY_PARENT/.ubuntu.new.$$"
  BACKUP_ROOT="$LEGACY_PARENT/.ubuntu.backup.$$"
fi
rm -rf "$NEW_ROOT" "$BACKUP_ROOT"
mkdir -p "$NEW_ROOT"

AVAILABLE="$(free_bytes)"; case "$AVAILABLE" in ''|*[!0-9]*) AVAILABLE=0;; esac
# File bytes + 512 MiB leaves room for directories, metadata, zstd buffers and the swap.
REQUIRED=$((ROOTFS_FILE_BYTES + 536870912))
if [ "$AVAILABLE" -lt "$REQUIRED" ]; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "저장공간 부족 · 고속 해제 필요 $((REQUIRED/1048576))MB / 사용 가능 $((AVAILABLE/1048576))MB · 기존 환경 유지"
  exit 46
fi

# GNU tar checkpoints track uncompressed records while zstd supplies the stream. This
# makes 82% visibly advance and allows a true no-progress watchdog instead of hanging.
CHECKPOINT_HELPER="$STATE_DIR/extract-checkpoint-helper.sh"
cat > "$CHECKPOINT_HELPER" <<'HELPER'
#!/data/data/com.termux/files/usr/bin/bash
set +e
f="$HOME/.desktab/extract-checkpoint"
t="$f.tmp.${BASHPID:-$$}"
printf '%s\n' "${TAR_CHECKPOINT:-0}" > "$t"
mv -f "$t" "$f"
HELPER
chmod +x "$CHECKPOINT_HELPER"
: > "$EXTRACT_CHECKPOINT"
: > "$EXTRACT_LOG"
CHECKPOINT_INTERVAL=4096
RECORD_BYTES=10240
EXTRACT_START="$(date +%s)"
LAST_CHANGE="$EXTRACT_START"
LAST_CP=0
progress 82 75 "zstd 초고속 해제 시작 · 무정지 감시 활성"
(
