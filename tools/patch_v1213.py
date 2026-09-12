from pathlib import Path

p = Path('app/src/main/assets/bootstrap.sh')
s = p.read_text()
s = s.replace('deskTAB Chrome Linux bootstrap v6.5 시작', 'deskTAB Chrome Linux bootstrap v7.0 시작')

start = s.index('progress 12 170 "사전 구성 Linux 이미지 정보 확인"')
end = s.index('\nprogress 97 7 "원클릭 Chrome 실행 환경 구성"', start)

block = r'''progress 12 170 "사전 구성 Linux 이미지 버전 고정"
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
    if [ -f "$f" ]; then
      size="$(stat -c %s "$f" 2>/dev/null || printf '0')"
      [ "$size" -gt "$expected" ] && size="$expected"
      done=$((done + size))
    fi
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

[ -d "$LEGACY_ROOT" ] && mv "$LEGACY_ROOT" "$BACKUP_LEGACY"
[ -d "$MODERN_CONTAINER" ] && mv "$MODERN_CONTAINER" "$BACKUP_MODERN"
mv "$NEW_ROOT" "$LEGACY_ROOT"

progress 94 16 "Linux 네트워크 및 PRoot 확인"
mkdir -p "$LEGACY_ROOT/etc"
rm -f "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$LEGACY_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$LEGACY_ROOT/etc/hosts"

if proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'mkdir -p /tmp/runtime-root; chmod 700 /tmp/runtime-root; true'; then
  rm -rf "$BACKUP_LEGACY" "$BACKUP_MODERN"
else
  rm -rf "$LEGACY_ROOT" "$MODERN_CONTAINER"
  [ -d "$BACKUP_LEGACY" ] && mv "$BACKUP_LEGACY" "$LEGACY_ROOT"
  [ -d "$BACKUP_MODERN" ] && mv "$BACKUP_MODERN" "$MODERN_CONTAINER"
  progress 94 0 "PRoot 첫 로그인 실패 · 기존 환경 복원 완료"
  exit 47
fi'''

s = s[:start] + block + s[end:]
s = s.replace('rm -rf "$CACHE_DIR"\nmkdir -p "$CACHE_DIR"\nprintf \'%s\\n\' \'6\' > "$STATE_DIR/engine-version"',
              'rm -rf "$CACHE_ROOT"\nmkdir -p "$CACHE_ROOT"\nprintf \'%s\\n\' \'7\' > "$STATE_DIR/engine-version"')
p.write_text(s)

g = Path('app/build.gradle')
gs = g.read_text().replace('versionCode 15', 'versionCode 16').replace("versionName '1.2.12'", "versionName '1.2.13'")
g.write_text(gs)

m = Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java')
ms = m.read_text().replace('private static final int ENGINE_VERSION = 6;', 'private static final int ENGINE_VERSION = 7;')
ms = ms.replace('단일 설치 + heartbeat v6 준비', '검증 다운로드 + heartbeat v7 준비')
ms = ms.replace('v6은 중복 실행을 자동 차단합니다.', 'v7은 중복 실행을 자동 차단합니다.')
m.write_text(ms)

w = Path('.github/workflows/build-apk.yml')
ws = w.read_text()
needle = '      - name: Validate Termux bootstrap\n        run: bash -n app/src/main/assets/bootstrap.sh\n'
replacement = '''      - name: Validate Termux bootstrap\n        run: |\n          bash -n app/src/main/assets/bootstrap.sh\n          grep -q 'download_part() (' app/src/main/assets/bootstrap.sh\n          grep -q 'RUNTIME_COMMIT' app/src/main/assets/bootstrap.sh\n          grep -q 'verify_part_file' app/src/main/assets/bootstrap.sh\n          grep -q 'validate_xz_archive' app/src/main/assets/bootstrap.sh\n          grep -q '기존 환경 복원 완료' app/src/main/assets/bootstrap.sh\n          ! grep -q 'repair_part_atomically' app/src/main/assets/bootstrap.sh\n'''
if needle in ws:
    ws = ws.replace(needle, replacement)
w.write_text(ws)
