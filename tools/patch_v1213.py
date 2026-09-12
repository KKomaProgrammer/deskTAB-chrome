from pathlib import Path

# Keep the already-working pre-download stages unchanged. This script only audits
# the new downloader/extraction path and synchronizes the Java engine version.

# 1) SetupService must use the same engine version as MainActivity.
srv = Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/SetupService.java')
ss = srv.read_text().replace('public static final int ENGINE_VERSION = 6;', 'public static final int ENGINE_VERSION = 7;')
srv.write_text(ss)

# 2) Update the stale UI footer so it describes the current engine instead of v1.2.7.
main = Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java')
ms = main.read_text()
old_note = 'v1.2.7은 heartbeat 진행률을 단조 증가로 처리해 오래된 2% 상태가 이후 진행률을 덮어쓰지 못합니다. 설치 자체와 다운로드 진행률은 그대로 유지됩니다.'
new_note = 'v1.2.13은 런타임 버전을 고정하고 각 조각의 크기와 SHA-256을 다운로드 단계에서 검증합니다. 검증된 파일만 설치에 사용하며, 압축 해제와 PRoot 전환 실패 시 기존 환경을 보존합니다.'
ms = ms.replace(old_note, new_note)
main.write_text(ms)

# 3) Harden the post-download swap: configure the NEW rootfs before replacing
#    anything, and roll back explicitly if any rename fails.
b = Path('app/src/main/assets/bootstrap.sh')
s = b.read_text()
old = r'''if ! extract_runtime "$NEW_ROOT" "${PART_PATHS[@]}"; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "Linux 이미지 압축 해제 실패 · 기존 환경 유지"
  exit 46
fi

[ -d "$LEGACY_ROOT" ] && mv "$LEGACY_ROOT" "$BACKUP_LEGACY"
[ -d "$MODERN_CONTAINER" ] && mv "$MODERN_CONTAINER" "$BACKUP_MODERN"
mv "$NEW_ROOT" "$LEGACY_ROOT"

progress 94 16 "Linux 네트워크 및 PRoot 확인"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"

if proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'; then
'''
new = r'''if ! extract_runtime "$NEW_ROOT" "${PART_PATHS[@]}"; then
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
'''
if old not in s:
    raise SystemExit('expected extraction/swap block not found')
s = s.replace(old, new)

# 4) Count active .partial bytes in progress so large 48 MiB chunks do not look frozen.
old_progress = r'''    f="$CACHE_DIR/$part"
    if [ -f "$f" ]; then
      size="$(stat -c %s "$f" 2>/dev/null || printf '0')"
      [ "$size" -gt "$expected" ] && size="$expected"
      done=$((done + size))
    fi
'''
new_progress = r'''    f="$CACHE_DIR/$part"
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
'''
if old_progress not in s:
    raise SystemExit('expected download progress block not found')
s = s.replace(old_progress, new_progress)

b.write_text(s)
