#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
ROOT_FIX="$TMP_BASE/desktab-root-fix-v16.sh"
HB_STATE="$STATE_DIR/repair-heartbeat-state"
HB_PID=""
UBUNTU_ROOT_FILE="$STATE_DIR/ubuntu-root-path"
GUEST_EXEC="$STATE_DIR/guest-exec.sh"
XSTARTUP="$STATE_DIR/xstartup.sh"
OPEN_CHROME="$STATE_DIR/open-chrome.sh"
STOP_DESKTOP="$STATE_DIR/stop.sh"
mkdir -p "$STATE_DIR" "$TMP_BASE"

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
  while true; do write_heartbeat; sleep 2; done
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

raw_guest_probe() {
  local root="$1"; shift
  command -v proot >/dev/null 2>&1 || return 127
  local -a args
  args=(proot -0 -r "$root" -w /root -b /dev -b /proc -b /sys -b "$TMP_BASE:/tmp")
  local bind
  for bind in /storage /sdcard /system /apex; do [ -e "$bind" ] && args+=(-b "$bind"); done
  "${args[@]}" /usr/bin/env -i \
    HOME=/root USER=root LOGNAME=root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 "$@"
}

progress 90 18 "데스크톱 실행 환경 확인"
heartbeat_loop &
HB_PID=$!

UBUNTU_ROOT="$(find_ubuntu_root || true)"
[ -n "$UBUNTU_ROOT" ] || fail "Ubuntu/Chrome 환경을 찾지 못했습니다"
printf '%s\n' "$UBUNTU_ROOT" > "$UBUNTU_ROOT_FILE"
mkdir -p "$UBUNTU_ROOT/usr/bin" "$UBUNTU_ROOT/tmp/runtime-root"
chmod 700 "$UBUNTU_ROOT/tmp/runtime-root" 2>/dev/null || true
if [ ! -e "$UBUNTU_ROOT/usr/bin/google-chrome-stable" ] \
  && [ ! -L "$UBUNTU_ROOT/usr/bin/google-chrome-stable" ]; then
  ln -s /opt/google/chrome/google-chrome "$UBUNTU_ROOT/usr/bin/google-chrome-stable" \
    || fail "Chrome 실행 링크 복구 실패"
fi

PD_OK=0
if command -v proot-distro >/dev/null 2>&1; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome' \
      >/dev/null 2>&1
  else
    proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
      'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome' \
      >/dev/null 2>&1
  fi
  [ "$?" -eq 0 ] && PD_OK=1
  set -e
fi
if [ "$PD_OK" -eq 0 ]; then
  raw_guest_probe "$UBUNTU_ROOT" /bin/bash -lc \
    'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && test -x /opt/google/chrome/google-chrome' \
    >/dev/null 2>&1 || fail "Ubuntu rootfs 실행 확인 실패"
fi

progress 93 12 "앱 반복 실행 및 지속 세션 수리"
cat > "$ROOT_FIX" <<'ROOTFIX'
#!/bin/bash
set -eu
mkdir -p /usr/local/bin \
  /root/.local/share/applications \
  /root/.local/share/xfce4/helpers \
  /root/.config/xfce4 \
  /root/.cache/sessions \
  /tmp/runtime-root
chmod 700 /tmp/runtime-root || true

cat > /usr/local/bin/desktab-terminal <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
export TERM="${TERM:-xterm-256color}"
exec /usr/bin/xfce4-terminal --disable-server "$@"
EOF
chmod 755 /usr/local/bin/desktab-terminal
ln -sf /usr/local/bin/desktab-terminal /usr/local/bin/x-terminal-emulator

cat > /usr/local/bin/desktab-file-manager <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
exec /usr/bin/thunar "$@"
EOF
chmod 755 /usr/local/bin/desktab-file-manager

cat > /usr/local/bin/desktab-chrome <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
PROFILE="${HOME}/.config/google-chrome"
mkdir -p "$PROFILE" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
FLAGS=(
  --no-sandbox
  --disable-dev-shm-usage
  --password-store=basic
  --renderer-process-limit=3
  --no-first-run
  --no-default-browser-check
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
if [ "${DESKTAB_SOFTWARE_RENDERING:-0}" = "1" ]; then
  FLAGS+=(--disable-gpu)
fi
if [ "$#" -eq 0 ]; then
  exec /usr/bin/google-chrome-stable "${FLAGS[@]}" --new-window about:blank
else
  exec /usr/bin/google-chrome-stable "${FLAGS[@]}" --new-window "$@"
fi
EOF
chmod 755 /usr/local/bin/desktab-chrome

cat > /usr/local/bin/desktab-xfce-inner <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
SESSION_ENV=/tmp/desktab-session.env
umask 077
{
  printf 'export DISPLAY=%q\n' "$DISPLAY"
  printf 'export XDG_RUNTIME_DIR=%q\n' "$XDG_RUNTIME_DIR"
  printf 'export DBUS_SESSION_BUS_ADDRESS=%q\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
  printf 'export PULSE_SERVER=%q\n' "$PULSE_SERVER"
} > "$SESSION_ENV"
xfce4-session &
session_pid=$!
for _ in $(seq 1 40); do
  if pgrep -x xfconfd >/dev/null 2>&1; then
    xfconf-query -c xfwm4 -p /general/use_compositing -s false >/dev/null 2>&1 || true
    break
  fi
  sleep 0.15
done
wait "$session_pid"
rm -f "$SESSION_ENV"
EOF
chmod 755 /usr/local/bin/desktab-xfce-inner

cat > /usr/local/bin/desktab-xfce-session <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true
rm -f /tmp/desktab-session.env
if command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- /usr/local/bin/desktab-xfce-inner
fi
exec dbus-launch --exit-with-session /usr/local/bin/desktab-xfce-inner
EOF
chmod 755 /usr/local/bin/desktab-xfce-session

cat > /root/.local/share/xfce4/helpers/custom-TerminalEmulator.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=TerminalEmulator
X-XFCE-Binaries=desktab-terminal;xfce4-terminal;
X-XFCE-Commands=/usr/local/bin/desktab-terminal
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-terminal -x "%s"
Icon=xfce4-terminal
Name=deskTAB Terminal
StartupNotify=false
EOF
cat > /root/.local/share/xfce4/helpers/custom-WebBrowser.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=WebBrowser
X-XFCE-Binaries=desktab-chrome;google-chrome-stable;google-chrome;
X-XFCE-Commands=/usr/local/bin/desktab-chrome
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-chrome "%s"
Icon=google-chrome
Name=deskTAB Chrome
StartupNotify=false
EOF
cat > /root/.local/share/xfce4/helpers/custom-FileManager.desktop <<'EOF'
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=FileManager
X-XFCE-Binaries=desktab-file-manager;thunar;
X-XFCE-Commands=/usr/local/bin/desktab-file-manager
X-XFCE-CommandsWithParameter=/usr/local/bin/desktab-file-manager "%s"
Icon=system-file-manager
Name=deskTAB File Manager
StartupNotify=false
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
Exec=/usr/local/bin/desktab-chrome %U
Terminal=false
Type=Application
Icon=google-chrome
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=false
EOF
cat > /root/.local/share/applications/xfce4-terminal.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Name=Terminal Emulator
Exec=/usr/local/bin/desktab-terminal
TryExec=/usr/local/bin/desktab-terminal
Icon=org.xfce.terminal
Terminal=false
Type=Application
Categories=System;TerminalEmulator;
StartupNotify=false
EOF
mkdir -p /root/.config
cat > /root/.config/mimeapps.list <<'EOF'
[Default Applications]
text/html=google-chrome.desktop
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
inode/directory=thunar.desktop
EOF
update-desktop-database /root/.local/share/applications >/dev/null 2>&1 || true

test -x /usr/local/bin/desktab-terminal
test -x /usr/local/bin/desktab-chrome
test -x /usr/local/bin/desktab-xfce-session
grep -q '^X-XFCE-Binaries=' /root/.local/share/xfce4/helpers/custom-TerminalEmulator.desktop
grep -q '^TerminalEmulator=custom-TerminalEmulator$' /root/.config/xfce4/helpers.rc
ROOTFIX
chmod 700 "$ROOT_FIX"

run_guest_now() {
  if [ "$PD_OK" -eq 1 ]; then
    proot-distro login ubuntu --shared-tmp -- "$@"
  else
    raw_guest_probe "$UBUNTU_ROOT" "$@"
  fi
}
run_guest_now /bin/bash /tmp/desktab-root-fix-v16.sh || {
  rm -f "$ROOT_FIX"
  fail "XFCE/Chrome 실행 환경 수리 실패"
}
rm -f "$ROOT_FIX"

progress 96 6 "자가 복구 부팅 및 성능 실행기 구성"
printf -v ROOT_Q '%q' "$UBUNTU_ROOT"
printf -v TMP_Q '%q' "$TMP_BASE"
if [ "$PD_OK" -eq 1 ]; then GUEST_MODE="proot-distro"; else GUEST_MODE="raw"; fi
printf -v GUEST_MODE_Q '%q' "$GUEST_MODE"
cat > "$GUEST_EXEC" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set +e
ROOT=$ROOT_Q
TMP_BASE=$TMP_Q
GUEST_MODE=$GUEST_MODE_Q
if [ "\$GUEST_MODE" = "proot-distro" ]; then
  exec proot-distro login ubuntu --shared-tmp -- "\$@"
fi
args=(proot -0 -r "\$ROOT" -w /root -b /dev -b /proc -b /sys -b "\$TMP_BASE:/tmp")
for bind in /storage /sdcard /system /apex; do [ -e "\$bind" ] && args+=(-b "\$bind"); done
exec "\${args[@]}" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TERM="\${TERM:-xterm-256color}" LANG=C.UTF-8 "\$@"
EOF
chmod 700 "$GUEST_EXEC"

cat > "$XSTARTUP" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set +e
STATE_DIR="$HOME/.desktab"
exec "$STATE_DIR/guest-exec.sh" /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  export PULSE_SERVER=127.0.0.1
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
  exec /usr/local/bin/desktab-xfce-session
'
EOF
chmod 700 "$XSTARTUP"

cat > "$OPEN_CHROME" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set +e
STATE_DIR="$HOME/.desktab"
exec "$STATE_DIR/guest-exec.sh" /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  export PULSE_SERVER=127.0.0.1
  [ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
  exec /usr/local/bin/desktab-chrome about:blank
'
EOF
chmod 700 "$OPEN_CHROME"

cat > "$STATE_DIR/launch.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set +e
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
GUEST="$STATE_DIR/guest-exec.sh"
XSTARTUP="$STATE_DIR/xstartup.sh"
OPEN_CHROME="$STATE_DIR/open-chrome.sh"
XSOCKET="$TMP_BASE/.X11-unix/X1"
STATUS="$STATE_DIR/desktop-status"
LOCK="$STATE_DIR/desktop-launch.lock"
export XDG_RUNTIME_DIR="$TMP_BASE"
mkdir -p "$STATE_DIR" "$TMP_BASE/.X11-unix"
termux-wake-lock >/dev/null 2>&1 || true

status() { printf '%s|%s\n' "$(date +%s)" "$1" > "$STATUS"; }

if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

wait_for_x11() {
  local i
  for i in $(seq 1 60); do
    [ -S "$XSOCKET" ] && return 0
    sleep 0.1
  done
  return 1
}

start_x11() {
  local legacy="${1:-0}"
  rm -f "$XSOCKET" "$TMP_BASE/.X1-lock"
  if [ "$legacy" = "1" ]; then
    termux-x11 :1 -legacy-drawing >"$STATE_DIR/x11.log" 2>&1 &
  else
    termux-x11 :1 >"$STATE_DIR/x11.log" 2>&1 &
  fi
  wait_for_x11
}

ensure_x11_server() {
  if pgrep -f '[t]ermux-x11 :1' >/dev/null 2>&1 && [ -S "$XSOCKET" ]; then
    return 0
  fi
  pkill -x termux-x11 >/dev/null 2>&1 || true
  sleep 0.15
  if start_x11 0; then return 0; fi
  pkill -x termux-x11 >/dev/null 2>&1 || true
  sleep 0.15
  start_x11 1
}

session_alive() {
  [ -s "$TMP_BASE/desktab-session.env" ] || return 1
  "$GUEST" /bin/bash -lc 'pgrep -x xfce4-session >/dev/null 2>&1' >/dev/null 2>&1
}

start_desktop_session() {
  rm -f "$TMP_BASE/desktab-session.env"
  "$GUEST" /bin/bash -lc '
    pkill -x xfce4-session >/dev/null 2>&1 || true
    pkill -x xfconfd >/dev/null 2>&1 || true
    pkill -x xfsettingsd >/dev/null 2>&1 || true
    pkill -x xfdesktop >/dev/null 2>&1 || true
    pkill -x xfce4-panel >/dev/null 2>&1 || true
    pkill -f desktab-xfce-session >/dev/null 2>&1 || true
  ' >/dev/null 2>&1 || true
  if command -v setsid >/dev/null 2>&1; then
    setsid "$XSTARTUP" >"$STATE_DIR/session.log" 2>&1 </dev/null &
  else
    nohup "$XSTARTUP" >"$STATE_DIR/session.log" 2>&1 </dev/null &
  fi
}

ensure_desktop_session() {
  local i
  session_alive && return 0
  start_desktop_session
  for i in $(seq 1 60); do
    if [ -s "$TMP_BASE/desktab-session.env" ] && session_alive; then return 0; fi
    sleep 0.15
  done
  return 1
}

launch_chrome_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$OPEN_CHROME" >"$STATE_DIR/chrome-launch.log" 2>&1 </dev/null &
  else
    nohup "$OPEN_CHROME" >"$STATE_DIR/chrome-launch.log" 2>&1 </dev/null &
  fi
}

status "START|X11 서버 확인"
if ! ensure_x11_server; then
  status "FAIL|X11 서버 시작 실패"
  exit 81
fi

/system/bin/am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
sleep 0.2
if [ ! -f "$STATE_DIR/x11-performance-v2" ] && command -v termux-x11-preference >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 termux-x11-preference displayResolutionMode=scaled displayScale=60 fullscreen=true >/dev/null 2>&1 || true
  else
    termux-x11-preference displayResolutionMode=scaled displayScale=60 fullscreen=true >/dev/null 2>&1 &
  fi
  touch "$STATE_DIR/x11-performance-v2"
fi

pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
if command -v pactl >/dev/null 2>&1; then
  if ! pactl list modules short 2>/dev/null | grep -q 'module-native-protocol-tcp'; then
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
  fi
fi
export PULSE_SERVER=127.0.0.1

status "START|XFCE 세션 확인"
if ! ensure_desktop_session; then
  # One full server/session restart handles stale X11 sockets and broken D-Bus together.
  pkill -x termux-x11 >/dev/null 2>&1 || true
  rm -f "$XSOCKET" "$TMP_BASE/.X1-lock" "$TMP_BASE/desktab-session.env"
  sleep 0.2
  if ! ensure_x11_server || ! ensure_desktop_session; then
    status "FAIL|XFCE 세션 시작 실패"
    exit 82
  fi
fi

status "OK|Desktop Chrome 실행"
launch_chrome_detached
exit 0
EOF
chmod 700 "$STATE_DIR/launch.sh"

cat > "$STOP_DESKTOP" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set +e
STATE_DIR="$HOME/.desktab"
"$STATE_DIR/guest-exec.sh" /bin/bash -lc '
  pkill -x chrome >/dev/null 2>&1 || true
  pkill -x google-chrome >/dev/null 2>&1 || true
  pkill -x xfce4-session >/dev/null 2>&1 || true
  pkill -f desktab-xfce-session >/dev/null 2>&1 || true
' >/dev/null 2>&1 || true
pkill -x termux-x11 >/dev/null 2>&1 || true
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
rm -f "$TMP_BASE/.X11-unix/X1" "$TMP_BASE/.X1-lock" "$TMP_BASE/desktab-session.env"
/system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
EOF
chmod 700 "$STOP_DESKTOP"

bash -n "$GUEST_EXEC"
bash -n "$XSTARTUP"
bash -n "$OPEN_CHROME"
bash -n "$STATE_DIR/launch.sh"
bash -n "$STOP_DESKTOP"

printf '%s\n' '6' > "$STATE_DIR/desktop-repair-version"
printf '%s\n' '11' > "$STATE_DIR/engine-version"
touch "$STATE_DIR/ready"
progress 100 0 "Desktop Chrome 준비 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
exit 0
