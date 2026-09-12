  set -o pipefail
  zstd -d -q -c "$ARCHIVE_FILE" \
    | tar --blocking-factor=20 --checkpoint="$CHECKPOINT_INTERVAL" --checkpoint-action="exec=$CHECKPOINT_HELPER" -xpf - -C "$NEW_ROOT"
) >"$EXTRACT_LOG" 2>&1 &
EXTRACT_PID=$!

while kill -0 "$EXTRACT_PID" >/dev/null 2>&1; do
  now="$(date +%s)"
  cp="$(cat "$EXTRACT_CHECKPOINT" 2>/dev/null || printf 0)"; case "$cp" in ''|*[!0-9]*) cp=0;; esac
  if [ "$cp" -gt "$LAST_CP" ]; then LAST_CP="$cp"; LAST_CHANGE="$now"; fi
  processed=$((cp * CHECKPOINT_INTERVAL * RECORD_BYTES))
  [ "$processed" -gt "$ROOTFS_TAR_SIZE" ] && processed="$ROOTFS_TAR_SIZE"
  elapsed=$((now - EXTRACT_START)); [ "$elapsed" -lt 1 ] && elapsed=1
  if [ "$processed" -gt 0 ]; then
    epct=$((82 + processed * 11 / ROOTFS_TAR_SIZE)); [ "$epct" -gt 93 ] && epct=93
    eta=$(((ROOTFS_TAR_SIZE - processed) * elapsed / processed + 8)); [ "$eta" -lt 5 ] && eta=5
    progress "$epct" "$eta" "zstd 고속 해제 · $((processed/1048576))/$((ROOTFS_TAR_SIZE/1048576))MB"
  else
    progress 82 75 "zstd 고속 해제 준비 · ${elapsed}초"
  fi
  if [ $((now - LAST_CHANGE)) -ge 120 ]; then
    kill_tree "$EXTRACT_PID"
    wait "$EXTRACT_PID" >/dev/null 2>&1 || true
    tail -n 20 "$EXTRACT_LOG" >&2 || true
    rm -rf "$NEW_ROOT"
    progress 82 0 "zstd 해제가 120초 동안 진행되지 않아 자동 중단 · 무한 대기 방지 · 기존 환경 유지"
    exit 46
  fi
  current_free="$(free_bytes)"; case "$current_free" in ''|*[!0-9]*) current_free=0;; esac
  if [ "$current_free" -gt 0 ] && [ "$current_free" -lt 134217728 ]; then
    kill_tree "$EXTRACT_PID"
    wait "$EXTRACT_PID" >/dev/null 2>&1 || true
    rm -rf "$NEW_ROOT"
    progress 82 0 "해제 중 저장공간이 128MB 미만으로 감소해 안전 중단 · 기존 환경 유지"
    exit 46
  fi
  sleep 1
done
set +e
wait "$EXTRACT_PID"; EXTRACT_RC=$?
set -e
if [ "$EXTRACT_RC" -ne 0 ]; then
  tail -n 30 "$EXTRACT_LOG" >&2 || true
  rm -rf "$NEW_ROOT"
  progress 82 0 "zstd Linux 이미지 해제 실패(code=$EXTRACT_RC) · 기존 환경 유지"
  exit 46
fi
progress 93 15 "zstd 고속 해제 완료 · 새 rootfs 검증"

mkdir -p "$NEW_ROOT/etc" "$NEW_ROOT/tmp/runtime-root"
chmod 700 "$NEW_ROOT/tmp/runtime-root" || true
rm -f "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' 'nameserver 8.8.8.8' 'nameserver 1.1.1.1' > "$NEW_ROOT/etc/resolv.conf"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$NEW_ROOT/etc/hosts"

# Atomic same-filesystem swap; the previous rootfs stays recoverable until every package check passes.
progress 94 12 "새 Linux 환경 원자적 교체 및 전체 패키지 검사"
if [ -d "$ACTIVE_ROOT" ]; then mv "$ACTIVE_ROOT" "$BACKUP_ROOT" || { rm -rf "$NEW_ROOT"; exit 47; }; fi
if ! mv "$NEW_ROOT" "$ACTIVE_ROOT"; then
  [ -d "$BACKUP_ROOT" ] && mv "$BACKUP_ROOT" "$ACTIVE_ROOT" || true
  progress 94 0 "새 Linux 환경 교체 실패 · 기존 환경 복원"
  exit 47
fi

VERIFY_CMD='set -e
command -v google-chrome-stable >/dev/null
command -v xfce4-session >/dev/null
command -v dbus-launch >/dev/null
test -f /root/.config/autostart/desktab-chrome.desktop
for pkg in xfce4 dbus-x11 ca-certificates curl wget gnupg xdg-utils fonts-noto fonts-noto-cjk google-chrome-stable; do
  dpkg-query -W -f="\${Status}" "$pkg" 2>/dev/null | grep -q "ok installed"
done
mkdir -p /tmp/runtime-root
chmod 700 /tmp/runtime-root'
if ! proot-distro login ubuntu --shared-tmp -- /bin/bash -lc "$VERIFY_CMD"; then
  rm -rf "$ACTIVE_ROOT"
  [ -d "$BACKUP_ROOT" ] && mv "$BACKUP_ROOT" "$ACTIVE_ROOT" || true
  progress 94 0 "Chrome/XFCE/필수 패키지 검증 실패 · 기존 환경 자동 복원"
  exit 47
fi
rm -rf "$BACKUP_ROOT"

progress 97 7 "원클릭 Chrome 실행 환경 구성"
cat > "$STATE_DIR/launch.sh" <<'LAUNCH'
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
  pkill -x chrome >/dev/null 2>&1 || true
  pkill -x google-chrome >/dev/null 2>&1 || true
  pkill -x xfce4-session >/dev/null 2>&1 || true
  exec dbus-launch --exit-with-session xfce4-session
'
LAUNCH
chmod +x "$STATE_DIR/launch.sh"

rm -rf "$CACHE_ROOT"
mkdir -p "$CACHE_ROOT"
printf '%s\n' '10' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "고속 설정 완료 · zstd 엔진 v10"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
log "설정 완료"
