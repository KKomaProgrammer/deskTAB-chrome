    while kill -0 "$pid" >/dev/null 2>&1; do
      now="$(date +%s)"
      elapsed=$((now - start))
      sig="$(stat -c '%s:%Y' "$PKG_LOG" 2>/dev/null || echo 0:0)"
      if [ "$sig" != "$last_sig" ]; then last_sig="$sig"; last_change="$now"; fi
      idle=$((now - last_change))
      line="$(tail -n 1 "$PKG_LOG" 2>/dev/null | tr '\r\n|' '   ' | cut -c1-100)"
      if [ "$idle" -ge 90 ]; then
        CURRENT_STAGE="$label · 출력 없음 ${idle}초 · 서버/패키지 관리자 대기"
        CURRENT_ETA=0
      elif [ -n "$line" ]; then
        CURRENT_STAGE="$label · $line"
        CURRENT_ETA=$((base_eta - elapsed)); [ "$CURRENT_ETA" -lt 15 ] && CURRENT_ETA=15
      else
        CURRENT_STAGE="$label · 처리 중 ${elapsed}초"
        CURRENT_ETA=$((base_eta - elapsed)); [ "$CURRENT_ETA" -lt 15 ] && CURRENT_ETA=15
      fi
      publish_state
      broadcast_progress "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE"
      sleep 2
    done
    set +e
    wait "$pid"; code=$?
    set -e
    cat "$PKG_LOG" 2>/dev/null || true
    [ "$code" -eq 0 ] && return 0
    if grep -qiE 'Could not get lock|Unable to acquire.*lock|frontend lock.*locked|dpkg frontend lock was locked' "$PKG_LOG" && [ "$attempt" -lt 30 ]; then
      progress "$CURRENT_PCT" 0 "$label · dpkg 잠금 해제 대기 ($attempt/30)"
      sleep 2
      continue
    fi
    return "$code"
  done
}

install_component() {
  local pct="$1" eta="$2" label="$3"; shift 3
  local missing=() p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if [ "${#missing[@]}" -eq 0 ]; then
    progress "$pct" "$eta" "$label · 이미 설치됨"
    return 0
  fi
  progress "$pct" "$eta" "$label · ${missing[*]}"
  run_pkg "$label" apt-get install -y -o Dpkg::Use-Pty=0 -o Acquire::Languages=none -o Acquire::Retries=3 "${missing[@]}"
}

resolve_runtime_commit() (
  trap - ERR
  set +e
  set +E
  local tmp="$STATE_DIR/runtime-branch.json.tmp.$$" out="$STATE_DIR/runtime-branch.json" sha attempt
  for attempt in 1 2 3 4 5 6; do
    rm -f "$tmp"
    if curl -fsSL --retry 2 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      'https://api.github.com/repos/KKomaProgrammer/deskTAB-chrome/branches/runtime-image' -o "$tmp"; then
      sha="$(grep -m1 -oE '"'"'"sha"'"'"[[:space:]]*:[[:space:]]*"'"'"[0-9a-f]{40}"'"'"' "$tmp" | grep -oE '[0-9a-f]{40}' | head -n1)"
      if printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
        mv -f "$tmp" "$out"
        printf '%s\n' "$sha"
        exit 0
      fi
    fi
    sleep 1
  done
  if [ -s "$out" ]; then
    sha="$(grep -m1 -oE '"'"'"sha"'"'"[[:space:]]*:[[:space:]]*"'"'"[0-9a-f]{40}"'"'"' "$out" | grep -oE '[0-9a-f]{40}' | head -n1)"
    if printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
      printf '%s\n' "$sha"
      exit 0
    fi
  fi
  exit 1
)

validate_manifest() (
  trap - ERR
  set +e
  set +E
  local f="$1" arch fmt total archive_sha tar_size file_bytes part_size declared count expected sum i row name size sha expected_name last
  local rows=()
  [ -s "$f" ] || exit 1
  arch="$(awk '$1=="ARCH"{print $2; exit}' "$f")"
  fmt="$(awk '$1=="FORMAT"{print $2; exit}' "$f")"
  total="$(awk '$1=="ARCHIVE_SIZE"{print $2; exit}' "$f")"
  archive_sha="$(awk '$1=="ARCHIVE_SHA256"{print $2; exit}' "$f")"
  tar_size="$(awk '$1=="ROOTFS_TAR_SIZE"{print $2; exit}' "$f")"
  file_bytes="$(awk '$1=="ROOTFS_FILE_BYTES"{print $2; exit}' "$f")"
  part_size="$(awk '$1=="PART_SIZE_BYTES"{print $2; exit}' "$f")"
  declared="$(awk '$1=="PART_COUNT"{print $2; exit}' "$f")"
  [ "$arch" = arm64 ] || exit 1
  [ "$fmt" = zst ] || exit 1
  for n in "$total" "$tar_size" "$file_bytes" "$part_size" "$declared"; do printf '%s' "$n" | grep -qE '^[0-9]+$' || exit 1; done
  [ "$total" -gt 0 ] && [ "$tar_size" -gt "$total" ] && [ "$file_bytes" -gt 0 ] && [ "$part_size" -gt 0 ] || exit 1
  printf '%s' "$archive_sha" | grep -qE '^[0-9a-f]{64}$' || exit 1
  mapfile -t rows < <(awk '$1=="PART"{print $2 "|" $3 "|" $4}' "$f")
  count="${#rows[@]}"
  expected=$(( (total + part_size - 1) / part_size ))
  [ "$count" -eq "$expected" ] && [ "$declared" -eq "$expected" ] || exit 1
  sum=0
  for ((i=0; i<count; i++)); do
    IFS='|' read -r name size sha <<< "${rows[$i]}"
    expected_name="$(printf 'runtime-arm64.part-%03d' "$i")"
    [ "$name" = "$expected_name" ] || exit 1
    printf '%s' "$size" | grep -qE '^[0-9]+$' || exit 1
    printf '%s' "$sha" | grep -qE '^[0-9a-f]{64}$' || exit 1
    if [ "$i" -lt $((count - 1)) ]; then
      [ "$size" -eq "$part_size" ] || exit 1
    else
      last=$((total - part_size * (count - 1)))
      [ "$size" -eq "$last" ] || exit 1
    fi
    sum=$((sum + size))
  done
  [ "$sum" -eq "$total" ] || exit 1
)

verify_part() {
  local file="$1" expected_size="$2" expected_sha="$3" actual_size actual_sha
  [ -f "$file" ] || return 1
  actual_size="$(stat -c %s "$file" 2>/dev/null || printf 0)"
  [ "$actual_size" = "$expected_size" ] || return 1
  actual_sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" || return 1
  [ "$actual_sha" = "$expected_sha" ]
}

verify_archive() {
  local file="$1" actual_size actual_sha
  [ -f "$file" ] || return 1
  actual_size="$(stat -c %s "$file" 2>/dev/null || printf 0)"
  [ "$actual_size" = "$TOTAL_SIZE" ] || return 1
  actual_sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" || return 1
  [ "$actual_sha" = "$ARCHIVE_SHA" ]
}

fetch_manifest() (
  trap - ERR
  set +e
  set +E
  local tmp="$MANIFEST.tmp.$$" attempt base url
  for attempt in 1 2 3 4 5 6 7 8; do
    for base in "$RUNTIME_BASE" "$RUNTIME_BASE_ALT"; do
      rm -f "$tmp"
      url="$base/manifest.txt?runtime=$RUNTIME_COMMIT&attempt=$attempt"
      if curl -fL --retry 2 --retry-all-errors --retry-delay 1 --connect-timeout 15 --max-time 60 -H 'Cache-Control: no-cache' "$url" -o "$tmp" \
        && validate_manifest "$tmp"; then
        mv -f "$tmp" "$MANIFEST"
