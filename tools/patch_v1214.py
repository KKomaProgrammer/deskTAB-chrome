from pathlib import Path

# Keep the already-working pre-download stages unchanged. Only replace the
# post-download verification/extraction block and synchronize engine versions.
bootstrap = Path('app/src/main/assets/bootstrap.sh')
s = bootstrap.read_text()
s = s.replace('deskTAB Chrome Linux bootstrap v7.0 시작', 'deskTAB Chrome Linux bootstrap v8.0 시작')
start_marker = 'progress 79 30 "모든 조각 검증 완료 · 전체 이미지 SHA 확인"'
end_marker = '\nprogress 97 7 "원클릭 Chrome 실행 환경 구성"'
start = s.index(start_marker)
end = s.index(end_marker, start)

block = r'''progress 79 35 "모든 조각 검증 완료 · 단일 XZ 이미지 조립"
ARCHIVE_FILE="$CACHE_DIR/runtime-arm64.tar.xz"
ARCHIVE_TMP="$CACHE_DIR/.runtime-arm64.tar.xz.assembling"
rm -f "$ARCHIVE_TMP"
if ! : > "$ARCHIVE_TMP"; then
  progress 79 0 "Linux 이미지 조립 파일 생성 실패 · 저장공간/파일시스템 확인"
  exit 44
fi

ASSEMBLED_SIZE=0
while read -r kind part size sha; do
  [ "$kind" = "PART" ] || continue
  part_path="$CACHE_DIR/$part"
  # 79%에 들어오기 전에 이미 검증했지만, 조립 직전에도 다시 확인한다.
  if ! verify_part_file "$part_path" "$size" "$sha"; then
    rm -f "$ARCHIVE_TMP"
    progress 78 0 "Linux 이미지 조각이 조립 직전에 변경됨 · $part"
    exit 43
  fi
  if ! cat "$part_path" >> "$ARCHIVE_TMP"; then
    rm -f "$ARCHIVE_TMP"
    progress 79 0 "Linux 이미지 조립 실패 · $part 읽기/저장 오류"
    exit 44
  fi
  ASSEMBLED_SIZE=$((ASSEMBLED_SIZE + size))
  ASSEMBLY_PCT=$((79 + ASSEMBLED_SIZE * 2 / TOTAL_SIZE))
  [ "$ASSEMBLY_PCT" -gt 81 ] && ASSEMBLY_PCT=81
  progress "$ASSEMBLY_PCT" 25 "검증된 Linux 이미지 조립 $((ASSEMBLED_SIZE / 1048576))/$((TOTAL_SIZE / 1048576))MB"
done < "$MANIFEST"

ACTUAL_ARCHIVE_SIZE="$(stat -c %s "$ARCHIVE_TMP" 2>/dev/null || printf '0')"
if [ "$ACTUAL_ARCHIVE_SIZE" != "$TOTAL_SIZE" ]; then
  rm -f "$ARCHIVE_TMP"
  progress 81 0 "Linux 이미지 조립 크기 불일치 · ${ACTUAL_ARCHIVE_SIZE}/${TOTAL_SIZE} bytes"
  exit 44
fi

# 각 part가 고정된 manifest의 SHA-256을 모두 통과했으므로 이 파일의 바이트열은
# manifest가 지정한 아카이브와 동일하다. 이전의 cat|sha256sum 전체 파이프 검사는
# Termux에서 불필요한 실패 지점이었으므로 제거한다. 단일 파일 XZ 검증으로 최종 확인한다.
mv -f "$ARCHIVE_TMP" "$ARCHIVE_FILE"
sync "$ARCHIVE_FILE" >/dev/null 2>&1 || true

progress 81 20 "단일 Linux XZ 이미지 구조 확인"
if ! xz -t "$ARCHIVE_FILE"; then
  progress 81 0 "Linux XZ 이미지 구조 검사 실패"
  exit 45
fi

# 단일 아카이브가 완성됐으므로 분할 조각을 제거해 압축 해제 공간을 확보한다.
while read -r kind part _ _; do
  [ "$kind" = "PART" ] || continue
  rm -f "$CACHE_DIR/$part"
done < "$MANIFEST"

progress 82 38 "Ubuntu + XFCE + Chrome 이미지 고속 해제"
LEGACY_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
MODERN_CONTAINER="$PREFIX/var/lib/proot-distro/containers/ubuntu"
NEW_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/.ubuntu.new.$$"
BACKUP_LEGACY="$PREFIX/var/lib/proot-distro/installed-rootfs/.ubuntu.backup.$$"
BACKUP_MODERN="$PREFIX/var/lib/proot-distro/containers/.ubuntu.backup.$$"
mkdir -p "$(dirname "$LEGACY_ROOT")" "$(dirname "$MODERN_CONTAINER")"
rm -rf "$NEW_ROOT" "$BACKUP_LEGACY" "$BACKUP_MODERN"
mkdir -p "$NEW_ROOT"

# 파이프 없이 GNU tar가 XZ 파일을 직접 읽게 해 SIGPIPE/pipefail 계열 실패를 제거한다.
if ! tar -xJpf "$ARCHIVE_FILE" -C "$NEW_ROOT"; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "Linux 이미지 압축 해제 실패 · 기존 환경 유지 · 저장공간 확인"
  exit 46
fi

# 새 rootfs 준비는 기존 환경을 건드리기 전에 모두 끝낸다.
if ! mkdir -p "$NEW_ROOT/etc"; then
  rm -rf "$NEW_ROOT"
  progress 82 0 "새 Linux 환경 준비 실패 · 기존 환경 유지"
  exit 46
fi
rm -f "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$NEW_ROOT/etc/hosts"

# 같은 Termux 파일시스템 안의 rename으로 교체한다. 어느 단계든 실패하면 기존 환경 복원.
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
if proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; command -v google-chrome-stable >/dev/null; command -v xfce4-session >/dev/null'; then
  rm -rf "$BACKUP_LEGACY" "$BACKUP_MODERN"
else
  rm -rf "$LEGACY_ROOT" "$MODERN_CONTAINER"
  [ -d "$BACKUP_LEGACY" ] && mv "$BACKUP_LEGACY" "$LEGACY_ROOT"
  [ -d "$BACKUP_MODERN" ] && mv "$BACKUP_MODERN" "$MODERN_CONTAINER"
  progress 94 0 "PRoot/Chrome/XFCE 확인 실패 · 기존 환경 복원 완료"
  exit 47
fi
'''

s = s[:start] + block + s[end:]
s = s.replace("printf '%s\\n' '7' > \"$STATE_DIR/engine-version\"", "printf '%s\\n' '8' > \"$STATE_DIR/engine-version\"")
bootstrap.write_text(s)

# Bump app version and synchronize both Java engine-version constants.
gradle = Path('app/build.gradle')
g = gradle.read_text()
g = g.replace("versionCode 16", "versionCode 17")
g = g.replace("versionName '1.2.13'", "versionName '1.2.14'")
gradle.write_text(g)

for java_path in [
    Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java'),
    Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/SetupService.java'),
]:
    j = java_path.read_text()
    j = j.replace('ENGINE_VERSION = 7', 'ENGINE_VERSION = 8')
    java_path.write_text(j)

main = Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java')
m = main.read_text()
old = 'v1.2.13은 런타임 버전을 고정하고 각 조각의 크기와 SHA-256을 다운로드 단계에서 검증합니다. 검증된 파일만 설치에 사용하며, 압축 해제와 PRoot 전환 실패 시 기존 환경을 보존합니다.'
new = 'v1.2.14는 검증된 조각을 단일 XZ 파일로 안전하게 조립한 뒤 파이프 없이 직접 검사·압축 해제합니다. 각 조각 SHA 검증과 기존 환경 원자적 보존은 그대로 유지합니다.'
m = m.replace(old, new)
main.write_text(m)
