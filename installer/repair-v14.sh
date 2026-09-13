#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
ROOT_FIX="$TMP_BASE/desktab-root-fix.sh"
HB_STATE="$STATE_DIR/repair-heartbeat-state"
HB_PID=""
UBUNTU_ROOT_FILE="$STATE_DIR/ubuntu-root-path"
mkdir -p "$STATE_DIR"

write_heartbeat() {
  local state tmp
  state="$(cat "$HB_STATE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$STATE_DIR/heartbeat.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$$" "$state" > "$tmp"
  mv -f "$tmp" "$STATE_DIR/heartbeat"
}

heartbeat_loop() {
  trap - ERR
  set +e
  set +E
  while true; do
    write_heartbeat
    sleep 2
  done
}

stop_heartbeat() {
  set +e
  if [ -n "$HB_PID" ]; then
    kill "$HB_PID" >/dev/null 2>&1 || true
    wait "$HB_PID" >/dev/null 2>&1 || true
    HB_PID=""
  fi
}
trap stop_heartbeat EXIT

progress() {
  local pct="$1" eta="$2" stage="$3" tmp
  tmp="$HB_STATE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$pct" "$eta" "$stage" > "$tmp"
  mv -f "$tmp" "$HB_STATE"
  write_heartbeat
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$pct" --el eta "$eta" --es stage "$stage" >/dev/null 2>&1 || true
}

fail() {
  local msg="$1"
  progress -1 0 "$msg"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "$msg" >/dev/null 2>&1 || true
  exit 1
}

find_ubuntu_root() {
  local root
  for root in \
    "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs" \
    "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"; do
    if [ -x "$root/usr/bin/bash" ] \
      && [ -x "$root/usr/bin/xfce4-session" ] \
      && [ -x "$root/usr/bin/xfce4-terminal" ] \
      && [ -x "$root/opt/google/chrome/google-chrome" ] \
      && [ -f "$root/var/lib/dpkg/status" ]; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  return 1
}

raw_guest() {
  local root="$1"; shift
  command -v proot >/dev/null 2>&1 || return 127
  local -a args
  args=(proot -0 -r "$root" -w /root -b /dev -b /proc -b /sys -b "$TMP_BASE:/tmp")
  local bind
  for bind in /storage /sdcard /system /apex; do
    [ -e "$bind" ] && args+=(-b "$bind")
  done
  "${args[@]}" /usr/bin/env -i \
    HOME=/root USER=root LOGNAME=root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 "$@"
}

progress 91 20 "기존 Linux 환경 빠른 수리 시작"
heartbeat_loop &
HB_PID=$!

progress 92 15 "실제 Ubuntu rootfs 확인 · Chrome launcher 자동 복구"
UBUNTU_ROOT="$(find_ubuntu_root || true)"
[ -n "$UBUNTU_ROOT" ] || fail "데스크톱 수리 대상 rootfs를 찾지 못했습니다 · Ubuntu/Chrome 본체가 없습니다"
printf '%s\n' "$UBUNTU_ROOT" > "$UBUNTU_ROOT_FILE"

# Older/partially repaired environments can contain the real Chrome binary while
# /usr/bin/google-chrome-stable is missing. The previous repair treated that as if
# Chrome itself did not exist. Restore only this launcher; do not touch user data.
mkdir -p "$UBUNTU_ROOT/usr/bin" "$UBUNTU_ROOT/tmp/runtime-root"
chmod 700 "$UBUNTU_ROOT/tmp/runtime-root" 2>/dev/null || true
if [ ! -e "$UBUNTU_ROOT/usr/bin/google-chrome-stable" ] \
  && [ ! -L "$UBUNTU_ROOT/usr/bin/google-chrome-stable" ]; then
  ln -s /opt/google/chrome/google-chrome "$UBUNTU_ROOT/usr/bin/google-chrome-stable" \
    || fail "Chrome launcher 자동 복구 실패"
fi

# Prefer the normal proot-distro path. If its container registry/layout is stale,
# keep the already-valid rootfs and use raw PRoot instead of falsely declaring the
# desktop absent or redownloading the Linux image.
PD_OK=0
if command -v proot-distro >/dev/null 2>&1; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome && test -x /usr/bin/google-chrome-stable' \
      >/dev/null 2>&1
  else
    proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome && test -x /usr/bin/google-chrome-stable' \
      >/dev/null 2>&1
  fi
  [ "$?" -eq 0 ] && PD_OK=1
  set -e
fi
if [ "$PD_OK" -eq 0 ]; then
  progress 93 12 "PRoot-Distro 등록 복구 경로 · 기존 rootfs 유지"
  raw_guest "$UBUNTU_ROOT" /bin/bash -lc \
    'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome && test -x /usr/bin/google-chrome-stable' \
    >/dev/null 2>&1 || fail "Ubuntu rootfs 실행 확인 실패 · 기존 파일은 보존됨"
fi

progress 94 9 "XFCE/Chrome 반복 실행 수리"
cat > "$ROOT_FIX" <<'ROOTFIX'
#!/bin/bash
set -eu

mkdir -p /usr/local/bin \
  /root/.local/share/applications \
  /root/.local/share/xfce4/helpers \
  /root/.config/xfce4 \
  /root/.config/autostart \
  /root/.cache/sessions

cat > /usr/local/bin/desktab-terminal <<'EOF'
#!/bin/bash
exec /usr/bin/xfce4-terminal --disable-server "$@"
EOF
chmod 755 /usr/local/bin/desktab-terminal

cat > /usr/local/bin/desktab-file-manager <<'EOF'
#!/bin/bash
exec /usr/bin/thunar "$@"
EOF
chmod 755 /usr/local/bin/desktab-file-manager

cat > /usr/local/bin/desktab-chrome <<'EOF'
#!/bin/bash
set +e
PROFILE="${HOME}/.config/google-chrome"
mkdir -p "$PROFILE"
FLAGS=(
  --no-sandbox
  --disable-dev-shm-usage
  --password-store=basic
  --disable-gpu
  --renderer-process-limit=4
  --no-first-run
  --start-maximized
)
live=0
for pid in $(pgrep -f '/opt/google/chrome/google-chrome' 2>/dev/null); do
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$stat" in Z*|'') ;; *) live=1; break;; esac
done
if [ "$live" -eq 0 ]; then
  rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
fi
if [ "$#" -eq 0 ]; then
  exec /usr/bin/google-chrome-stable "${FLAGS[@]}" --new-window about:blank
else
  exec /usr/bin/google-chrome-stable "${FLAGS[@]}" --new-window "$@"
fi
EOF
chmod 755 /usr/local/bin/desktab-chrome

cat > /usr/local/bin/desktab-xfce-session <<'EOF'
#!/bin/bash
set +e
rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true
xfce4-session &
session_pid=$!
for _ in $(seq 1 30); do
  if pgrep -x xfconfd >/dev/null 2>&1; then
    xfconf-query -c xfwm4 -p /general/use_compositing -s false >/dev/null 2>&1 || true
    break
  fi
  sleep 0.2
done
wait "$session_pid"
EOF
chmod 755 /usr/local/bin/desktab-xfce-session

cat > /root/.local/share/xfce4/helpers/custom-TerminalEmulator.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=TerminalEmulator
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-terminal -x %s
Icon=xfce4-terminal
Name=deskTAB Terminal
X-XFCE-Commands=/usr/local/bin/desktab-terminal
EOF

cat > /root/.local/share/xfce4/helpers/custom-WebBrowser.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=WebBrowser
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-chrome %s
Icon=google-chrome
Name=deskTAB Chrome
X-XFCE-Commands=/usr/local/bin/desktab-chrome
EOF

cat > /root/.local/share/xfce4/helpers/custom-FileManager.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=FileManager
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-file-manager %s
Icon=system-file-manager
Name=deskTAB File Manager
X-XFCE-Commands=/usr/local/bin/desktab-file-manager
EOF

cat > /root/.config/xfce4/helpers.rc <<'EOF'
WebBrowser=custom-WebBrowser
FileManager=custom-FileManager
TerminalEmulator=custom-TerminalEmulator
EOF

cat > /root/.local/share/applications/google-chrome.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Name=Google Chrome
GenericName=Web Browser
Comment=Access the Internet
Exec=/usr/local/bin/desktab-chrome %U
Terminal=false
Type=Application
Icon=google-chrome
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml_xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF

cat > /root/.local/share/applications/xfce4-terminal.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Name=Terminal Emulator
Comment=Use the command line
Exec=/usr/local/bin/desktab-terminal
Icon=org.xfce.terminal
Terminal=false
Type=Application
Categories=System;TerminalEmulator;
StartupNotify=true
EOF

cat > /root/.config/autostart/desktab-chrome.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=deskTAB Chrome
Comment=Desktop Google Chrome
Exec=/usr/local/bin/desktab-chrome
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

update-desktop-database /root/.local/share/applications >/dev/null 2>&1 || true
ROOTFIX
chmod 700 "$ROOT_FIX"

if [ "$PD_OK" -eq 1 ]; then
  if ! proot-distro login ubuntu --shared-tmp -- /bin/bash /tmp/desktab-root-fix.sh; then
    rm -f "$ROOT_FIX"
    fail "XFCE/Chrome 반복 실행 수리 실패"
  fi
else
  if ! raw_guest "$UBUNTU_ROOT" /bin/bash /tmp/desktab-root-fix.sh; then
    rm -f "$ROOT_FIX"
    fail "XFCE/Chrome raw PRoot 수리 실패"
  fi
fi
rm -f "$ROOT_FIX"

progress 97 4 "저지연 실행기 및 네트워크 설정"
cat > "$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
ROOT="$(cat "$STATE_DIR/ubuntu-root-path" 2>/dev/null || true)"
export XDG_RUNTIME_DIR="$TMP_BASE"
termux-wake-lock >/dev/null 2>&1 || true
if ! pgrep -f '[t]ermux-x11 :1' >/dev/null 2>&1; then
  termux-x11 :1 >"$STATE_DIR/x11.log" 2>&1 &
  sleep 1
fi
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
if command -v pactl >/dev/null 2>&1; then
  if ! pactl list modules short 2>/dev/null | grep -q 'module-native-protocol-tcp'; then
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
  fi
fi
export PULSE_SERVER=127.0.0.1
RESOLV="$TMP_BASE/desktab-resolv.conf"
: > "$RESOLV"
for prop in net.dns1 net.dns2 net.dns3 net.dns4; do
  dns="$(/system/bin/getprop "$prop" 2>/dev/null || true)"
  case "$dns" in
    *.*.*.*|*:* ) grep -qxF "nameserver $dns" "$RESOLV" 2>/dev/null || printf 'nameserver %s\n' "$dns" >> "$RESOLV" ;;
  esac
done
if [ ! -s "$RESOLV" ]; then
  printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > "$RESOLV"
fi

GUEST_SCRIPT='export DISPLAY=:1
export XDG_RUNTIME_DIR=/tmp/runtime-root
export PULSE_SERVER=127.0.0.1
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
if [ -s /tmp/desktab-resolv.conf ]; then
  cp -f /tmp/desktab-resolv.conf /etc/resolv.conf 2>/dev/null || true
fi
if pgrep -x xfce4-session >/dev/null 2>&1; then
  /usr/local/bin/desktab-chrome about:blank >/tmp/desktab-chrome-launch.log 2>&1 &
  exit 0
fi
pkill -x xfconfd >/dev/null 2>&1 || true
pkill -x xfsettingsd >/dev/null 2>&1 || true
pkill -x xfdesktop >/dev/null 2>&1 || true
pkill -x xfce4-panel >/dev/null 2>&1 || true
pkill -f "dbus-daemon.*--session" >/dev/null 2>&1 || true
rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true
exec dbus-launch --exit-with-session /usr/local/bin/desktab-xfce-session'

# Keep the proven proot-distro route unchanged when it works.
if command -v proot-distro >/dev/null 2>&1; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 proot-distro login ubuntu --shared-tmp -- /bin/true >/dev/null 2>&1
  else
    proot-distro login ubuntu --shared-tmp -- /bin/true >/dev/null 2>&1
  fi
  PD_RC=$?
  set -e
  if [ "$PD_RC" -eq 0 ]; then
    exec proot-distro login ubuntu --shared-tmp -- /bin/bash -lc "$GUEST_SCRIPT"
  fi
fi

# Compatibility path for an intact rootfs whose proot-distro registry/layout is
# stale. This does not alter the rootfs and is used only after the normal route fails.
[ -n "$ROOT" ] && [ -x "$ROOT/usr/bin/bash" ] || { echo "deskTAB: Ubuntu rootfs path missing" >&2; exit 71; }
command -v proot >/dev/null 2>&1 || { echo "deskTAB: proot missing" >&2; exit 72; }
ARGS=(proot -0 -r "$ROOT" -w /root -b /dev -b /proc -b /sys -b "$TMP_BASE:/tmp")
for bind in /storage /sdcard /system /apex; do
  [ -e "$bind" ] && ARGS+=(-b "$bind")
done
exec "${ARGS[@]}" /usr/bin/env -i \
  HOME=/root USER=root LOGNAME=root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 \
  DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-root PULSE_SERVER=127.0.0.1 \
  /bin/bash -lc "$GUEST_SCRIPT"
LAUNCH
chmod 700 "$STATE_DIR/launch.sh"
printf '%s\n' '4' > "$STATE_DIR/desktop-repair-version"
printf '%s\n' '11' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"

progress 100 0 "데스크톱 rootfs/Chrome launcher/반복 실행 수리 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
exit 0
