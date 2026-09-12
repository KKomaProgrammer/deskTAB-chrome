from pathlib import Path

repo = Path('.')
bootstrap_path = repo / 'app/src/main/assets/bootstrap.sh'
s = bootstrap_path.read_text()

# Prefer an existing cached runtime commit so an in-progress 792 MB download is not
# discarded just because runtime-image is rebuilt while the user is installing.
old_select = 'RUNTIME_COMMIT="$(resolve_runtime_commit)"\n'
new_select = r'''CACHED_COMMIT=""
CACHED_BYTES=0
for cached_dir in "$CACHE_ROOT"/*; do
  [ -d "$cached_dir" ] || continue
  cached_name="$(basename "$cached_dir")"
  printf '%s' "$cached_name" | grep -qE '^[0-9a-f]{40}$' || continue
  cached_bytes="$(du -sk "$cached_dir" 2>/dev/null | awk '{print $1*1024}' || printf '0')"
  case "$cached_bytes" in ''|*[!0-9]*) cached_bytes=0;; esac
  if [ "$cached_bytes" -gt "$CACHED_BYTES" ]; then
    CACHED_COMMIT="$cached_name"
    CACHED_BYTES="$cached_bytes"
  fi
done
if [ -n "$CACHED_COMMIT" ] && [ "$CACHED_BYTES" -gt 0 ]; then
  RUNTIME_COMMIT="$CACHED_COMMIT"
  log "기존 다운로드 캐시의 런타임 커밋 재사용: $RUNTIME_COMMIT ($((CACHED_BYTES / 1048576))MB)"
else
  RUNTIME_COMMIT="$(resolve_runtime_commit)"
fi
'''
if old_select not in s:
    raise SystemExit('runtime selection marker missing')
s = s.replace(old_select, new_select, 1)

start = s.index('fetch_manifest() (')
end = s.index('progress 82 38 "Ubuntu + XFCE + Chrome 이미지 고속 해제"')

block = r'''PART_CHUNK_BYTES_DEFAULT=50331648

validate_manifest_file() (
  trap - ERR
  set +e
  set +E
  local f="$1" total archive_sha fmt part_size declared_count count expected_count sum last_expected version
  local i row name size sha expected_name
  local rows=()

  [ -s "$f" ] || exit 1
  [ "$(awk '$1=="ARCH"{print $2; exit}' "$f")" = "arm64" ] || exit 1
  [ "$(awk '$1=="FORMAT"{print $2; exit}' "$f")" = "xz" ] || exit 1

  total="$(awk '$1=="ARCHIVE_SIZE"{print $2; exit}' "$f")"
  archive_sha="$(awk '$1=="ARCHIVE_SHA256"{print $2; exit}' "$f")"
  version="$(awk '$1=="VERSION"{print $2; exit}' "$f")"
  part_size="$(awk '$1=="PART_SIZE_BYTES"{print $2; exit}' "$f")"
  declared_count="$(awk '$1=="PART_COUNT"{print $2; exit}' "$f")"
  [ -n "$part_size" ] || part_size="$PART_CHUNK_BYTES_DEFAULT"

  printf '%s' "$total" | grep -qE '^[0-9]+$' || exit 1
  printf '%s' "$part_size" | grep -qE '^[0-9]+$' || exit 1
  [ "$total" -gt 0 ] || exit 1
  [ "$part_size" -gt 0 ] || exit 1
  [ "${#archive_sha}" -eq 64 ] || exit 1
  printf '%s' "$archive_sha" | grep -qE '^[0-9a-f]+$' || exit 1
  [ "${#version}" -eq 40 ] || exit 1
  printf '%s' "$version" | grep -qE '^[0-9a-f]+$' || exit 1

  mapfile -t rows < <(awk '$1=="PART"{print $2 "|" $3 "|" $4}' "$f")
  count="${#rows[@]}"
  expected_count=$(( (total + part_size - 1) / part_size ))
  [ "$count" -eq "$expected_count" ] || exit 1
  if [ -n "$declared_count" ]; then
    printf '%s' "$declared_count" | grep -qE '^[0-9]+$' || exit 1
    [ "$declared_count" -eq "$count" ] || exit 1
  fi

  sum=0
  for ((i=0; i<count; i++)); do
    row="${rows[$i]}"
    IFS='|' read -r name size sha <<< "$row"
    expected_name="$(printf 'runtime-arm64.part-%03d' "$i")"
    [ "$name" = "$expected_name" ] || exit 1
    printf '%s' "$size" | grep -qE '^[0-9]+$' || exit 1
    [ "${#sha}" -eq 64 ] || exit 1
    printf '%s' "$sha" | grep -qE '^[0-9a-f]+$' || exit 1
    if [ "$i" -lt $((count - 1)) ]; then
      [ "$size" -eq "$part_size" ] || exit 1
    else
      last_expected=$((total - part_size * (count - 1)))
      [ "$size" -eq "$last_expected" ] || exit 1
    fi
    sum=$((sum + size))
  done
  [ "$sum" -eq "$total" ] || exit 1
  exit 0
)

fetch_manifest() (
  trap - ERR
  set +e
  set +E
  local tmp="$MANIFEST.tmp.$$" base code attempt url
  rm -f "$tmp"
  for attempt in 1 2 3 4 5 6 7 8; do
    for base in "$RUNTIME_BASE" "$RUNTIME_BASE_ALT"; do
      rm -f "$tmp"
      url="$base/manifest.txt?runtime=$RUNTIME_COMMIT&attempt=$attempt"
      curl -fL --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 60 \
        -H 'Cache-Control: no-cache' "$url" -o "$tmp"
      code=$?
      if [ "$code" -eq 0 ] && validate_manifest_file "$tmp"; then
        mv -f "$tmp" "$MANIFEST"
        exit 0
      fi
      log "manifest 응답 불완전/형식 오류 · 재시도 $attempt/8"
    done
    sleep 1
  done
  rm -f "$tmp"
  exit 1
)

if ! fetch_manifest; then
  progress 12 0 "사전 구성 Linux 이미지 manifest 완전성 확인 실패"
  exit 42
fi

TOTAL_SIZE="$(awk '$1=="ARCHIVE_SIZE"{print $2; exit}' "$MANIFEST")"
ARCHIVE_SHA="$(awk '$1=="ARCHIVE_SHA256"{print $2; exit}' "$MANIFEST")"
FORMAT="$(awk '$1=="FORMAT"{print $2; exit}' "$MANIFEST")"
PART_SIZE_BYTES="$(awk '$1=="PART_SIZE_BYTES"{print $2; exit}' "$MANIFEST")"
[ -n "$PART_SIZE_BYTES" ] || PART_SIZE_BYTES="$PART_CHUNK_BYTES_DEFAULT"

mapfile -t PART_NAMES < <(awk '$1=="PART"{print $2}' "$MANIFEST")
mapfile -t PART_SIZES < <(awk '$1=="PART"{print $3}' "$MANIFEST")
mapfile -t PART_SHAS < <(awk '$1=="PART"{print $4}' "$MANIFEST")
PART_COUNT="${#PART_NAMES[@]}"
if [ "$PART_COUNT" -le 0 ] || [ "${#PART_SIZES[@]}" -ne "$PART_COUNT" ] || [ "${#PART_SHAS[@]}" -ne "$PART_COUNT" ]; then
  progress 12 0 "Linux 이미지 manifest 배열 파싱 실패"
  exit 42
fi
log "manifest 완전성 확인: $PART_COUNT개 조각 · 총 $TOTAL_SIZE bytes"

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

verify_archive_file() {
  local file="$1" actual_size actual_line actual_sha
  [ -f "$file" ] || return 1
  actual_size="$(stat -c %s "$file" 2>/dev/null || printf '0')"
  [ "$actual_size" = "$TOTAL_SIZE" ] || return 1
  actual_line="$(sha256sum "$file" 2>/dev/null)" || return 1
  actual_sha="${actual_line%% *}"
  [ "$actual_sha" = "$ARCHIVE_SHA" ]
}

progress 13 165 "기존 Linux 이미지 캐시 검증"
for ((i=0; i<PART_COUNT; i++)); do
  part="${PART_NAMES[$i]}"
  size="${PART_SIZES[$i]}"
  sha="${PART_SHAS[$i]}"
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
done
rm -f "$CACHE_DIR"/.runtime-arm64.part-*.partial "$CACHE_ROOT"/.runtime-arm64.part-*.partial \
      "$CACHE_ROOT"/.runtime-arm64.part-*.repair.* 2>/dev/null || true

download_part() (
  trap - ERR
  set +e
  set +E
  local p="$1" expected_size="$2" expected_sha="$3"
  local out="$CACHE_DIR/$p" partial="$CACHE_DIR/.${p}.partial"
  local attempt url code

  if verify_part_file "$out" "$expected_size" "$expected_sha"; then
    rm -f "$partial"
    exit 0
  fi
  rm -f "$out" "$partial"

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    rm -f "$partial"
    if [ $((attempt % 2)) -eq 1 ]; then
      url="$RUNTIME_BASE/$p"
    else
      url="$RUNTIME_BASE_ALT/$p"
    fi
    curl -fL --retry 4 --retry-all-errors --retry-delay 1 --connect-timeout 15 \
      --speed-time 30 --speed-limit 1024 --max-time 600 \
      -H 'Cache-Control: no-cache' "$url" -o "$partial"
    code=$?
    if [ "$code" -eq 0 ] && verify_part_file "$partial" "$expected_size" "$expected_sha"; then
      mv -f "$partial" "$out"
      sync "$out" >/dev/null 2>&1 || true
      exit 0
    fi
    rm -f "$partial"
    sleep 1
  done
  exit 1
)

ARCHIVE_FILE="$CACHE_DIR/runtime-arm64.tar.xz"
ARCHIVE_TMP="$CACHE_DIR/.runtime-arm64.tar.xz.assembling"

if verify_archive_file "$ARCHIVE_FILE"; then
  progress 81 20 "기존 완성 Linux 이미지 검증 성공"
else
  rm -f "$ARCHIVE_FILE" "$ARCHIVE_TMP"
  progress 14 160 "Linux 이미지 병렬 다운로드 시작 ($PART_COUNT개 조각)"
  DOWNLOAD_PIDS=()
  DOWNLOAD_BATCH_FAILED=0
  START_TS="$(date +%s)"

  update_download_progress() {
    local done=0 f partial size now elapsed pct eta j expected
    for ((j=0; j<PART_COUNT; j++)); do
      f="$CACHE_DIR/${PART_NAMES[$j]}"
      partial="$CACHE_DIR/.${PART_NAMES[$j]}.partial"
      expected="${PART_SIZES[$j]}"
      if [ -f "$f" ]; then
        size="$(stat -c %s "$f" 2>/dev/null || printf '0')"
      elif [ -f "$partial" ]; then
        size="$(stat -c %s "$partial" 2>/dev/null || printf '0')"
      else
        size=0
      fi
      [ "$size" -gt "$expected" ] && size="$expected"
      done=$((done + size))
    done
    now="$(date +%s)"
    elapsed=$((now - START_TS)); [ "$elapsed" -lt 1 ] && elapsed=1
    pct=$((14 + done * 64 / TOTAL_SIZE)); [ "$pct" -gt 78 ] && pct=78
    if [ "$done" -ge "$TOTAL_SIZE" ]; then
      eta=20
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
        log "조각 다운로드 1차 작업 실패(code=$rc) · 최종 검증에서 자동 재시도"
      fi
    done
    DOWNLOAD_PIDS=()
    return 0
  }

  for ((i=0; i<PART_COUNT; i++)); do
    part="${PART_NAMES[$i]}"
    size="${PART_SIZES[$i]}"
    sha="${PART_SHAS[$i]}"
    if verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
      continue
    fi
    download_part "$part" "$size" "$sha" &
    DOWNLOAD_PIDS+=("$!")
    if [ "${#DOWNLOAD_PIDS[@]}" -ge 6 ]; then
      wait_download_batch
    fi
  done
  if [ "${#DOWNLOAD_PIDS[@]}" -gt 0 ]; then
    wait_download_batch
  fi
  update_download_progress

  # Sequential final pass: every single part must exist and match size + SHA before assembly.
  for ((i=0; i<PART_COUNT; i++)); do
    part="${PART_NAMES[$i]}"
    size="${PART_SIZES[$i]}"
    sha="${PART_SHAS[$i]}"
    if verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
      continue
    fi
    progress 78 30 "미완료 Linux 이미지 조각 최종 재다운로드 · $part"
    if ! download_part "$part" "$size" "$sha" || ! verify_part_file "$CACHE_DIR/$part" "$size" "$sha"; then
      progress 78 0 "Linux 이미지 조각 확보 실패 · $part"
      exit 43
    fi
  done

  progress 79 35 "16개 검증 조각으로 단일 Linux 이미지 조립"
  if ! : > "$ARCHIVE_TMP"; then
    progress 79 0 "Linux 이미지 조립 파일 생성 실패 · 저장공간 확인"
    exit 44
  fi
  ASSEMBLED_SIZE=0
  for ((i=0; i<PART_COUNT; i++)); do
    part="${PART_NAMES[$i]}"
    size="${PART_SIZES[$i]}"
    sha="${PART_SHAS[$i]}"
    part_path="$CACHE_DIR/$part"
    if ! verify_part_file "$part_path" "$size" "$sha"; then
      rm -f "$ARCHIVE_TMP"
      progress 78 0 "조립 직전 조각 검증 실패 · $part"
      exit 43
    fi
    if ! cat "$part_path" >> "$ARCHIVE_TMP"; then
      rm -f "$ARCHIVE_TMP"
      progress 79 0 "Linux 이미지 조립 쓰기 실패 · $part · 저장공간 확인"
      exit 44
    fi
    ASSEMBLED_SIZE=$((ASSEMBLED_SIZE + size))
    ACTUAL_PREFIX="$(stat -c %s "$ARCHIVE_TMP" 2>/dev/null || printf '0')"
    if [ "$ACTUAL_PREFIX" -ne "$ASSEMBLED_SIZE" ]; then
      rm -f "$ARCHIVE_TMP"
      progress 79 0 "Linux 이미지 조립 중 크기 불일치 · $part · ${ACTUAL_PREFIX}/${ASSEMBLED_SIZE}"
      exit 44
    fi
    ASSEMBLY_PCT=$((79 + ASSEMBLED_SIZE * 2 / TOTAL_SIZE))
    [ "$ASSEMBLY_PCT" -gt 81 ] && ASSEMBLY_PCT=81
    progress "$ASSEMBLY_PCT" 25 "Linux 이미지 조립 $((i + 1))/$PART_COUNT · $((ASSEMBLED_SIZE / 1048576))MB"
  done

  [ "$ASSEMBLED_SIZE" -eq "$TOTAL_SIZE" ] || {
    rm -f "$ARCHIVE_TMP"
    progress 81 0 "Linux 이미지 조립 합계 오류 · ${ASSEMBLED_SIZE}/${TOTAL_SIZE} bytes"
    exit 44
  }
  ACTUAL_ARCHIVE_SIZE="$(stat -c %s "$ARCHIVE_TMP" 2>/dev/null || printf '0')"
  [ "$ACTUAL_ARCHIVE_SIZE" -eq "$TOTAL_SIZE" ] || {
    rm -f "$ARCHIVE_TMP"
    progress 81 0 "Linux 이미지 조립 파일 크기 오류 · ${ACTUAL_ARCHIVE_SIZE}/${TOTAL_SIZE} bytes"
    exit 44
  }
  HASH_LINE="$(sha256sum "$ARCHIVE_TMP" 2>/dev/null)" || {
    rm -f "$ARCHIVE_TMP"
    progress 81 0 "단일 Linux 이미지 SHA 계산 실패"
    exit 44
  }
  CALC_SHA="${HASH_LINE%% *}"
  [ "$CALC_SHA" = "$ARCHIVE_SHA" ] || {
    rm -f "$ARCHIVE_TMP"
    progress 81 0 "단일 Linux 이미지 SHA 불일치"
    exit 44
  }
  mv -f "$ARCHIVE_TMP" "$ARCHIVE_FILE"
  sync "$ARCHIVE_FILE" >/dev/null 2>&1 || true
fi

# This is a direct single-file test, not a pipeline. It validates XZ before any old rootfs is touched.
progress 81 18 "단일 Linux 이미지 최종 구조 검사"
if ! verify_archive_file "$ARCHIVE_FILE" || ! xz -t "$ARCHIVE_FILE"; then
  progress 81 0 "Linux 이미지 최종 검증 실패"
  exit 45
fi

# The complete archive is now cryptographically identical to the published archive,
# so split parts are no longer needed and are removed to free extraction space.
for ((i=0; i<PART_COUNT; i++)); do
  rm -f "$CACHE_DIR/${PART_NAMES[$i]}"
done
rm -f "$CACHE_DIR"/.runtime-arm64.part-*.partial 2>/dev/null || true

'''
s = s[:start] + block + s[end:]

# Keep launcher behavior but avoid pkill -f matching the shell command itself.
s = s.replace('  pkill -f google-chrome-stable >/dev/null 2>&1 || true\n  pkill -f xfce4-session >/dev/null 2>&1 || true\n',
'''  pkill -x chrome >/dev/null 2>&1 || true
  pkill -x google-chrome >/dev/null 2>&1 || true
  pkill -x xfce4-session >/dev/null 2>&1 || true
''')
s = s.replace("printf '%s\\n' '8' > \"$STATE_DIR/engine-version\"", "printf '%s\\n' '9' > \"$STATE_DIR/engine-version\"")
s = s.replace('deskTAB Chrome Linux bootstrap v7.0 시작', 'deskTAB Chrome Linux bootstrap v9.0 시작')
bootstrap_path.write_text(s)

# Version/engine synchronization.
gradle = repo / 'app/build.gradle'
g = gradle.read_text().replace('versionCode 17', 'versionCode 18').replace("versionName '1.2.14'", "versionName '1.2.15'")
gradle.write_text(g)

main = repo / 'app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java'
m = main.read_text()
m = m.replace('private static final int ENGINE_VERSION = 8;', 'private static final int ENGINE_VERSION = 9;')
m = m.replace('검증 다운로드 + heartbeat v7 준비', '완전 manifest + 배열 설치 엔진 v9 준비')
m = m.replace('v1.2.14는 검증된 조각을 단일 XZ 파일로 안전하게 조립한 뒤 파이프 없이 직접 검사·압축 해제합니다. 각 조각 SHA 검증과 기존 환경 원자적 보존은 그대로 유지합니다.',
'''v1.2.15는 불완전 manifest를 거부하고 모든 이미지 조각을 고정 배열로 관리합니다. 조각 수·순서·크기·SHA와 완성 XZ SHA를 모두 확인한 뒤 기존 환경을 보존한 채 설치합니다.''')
m = m.replace('v7은 중복 실행을 자동 차단합니다.', 'v9은 중복 실행을 자동 차단합니다.')
m = m.replace('deskTAB Linux setup v6', 'deskTAB Linux setup v9')
m = m.replace("proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'pkill -f google-chrome-stable || true; pkill -f xfce4-session || true' >/dev/null 2>&1 || true; pkill -f 'termux-x11 :1' || true",
'''proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'pkill -x chrome || true; pkill -x google-chrome || true; pkill -x xfce4-session || true' >/dev/null 2>&1 || true; pkill -x termux-x11 || true''')
main.write_text(m)

service = repo / 'app/src/main/java/com/kkomaprogrammer/desktabchrome/SetupService.java'
sv = service.read_text().replace('public static final int ENGINE_VERSION = 8;', 'public static final int ENGINE_VERSION = 9;')
service.write_text(sv)
