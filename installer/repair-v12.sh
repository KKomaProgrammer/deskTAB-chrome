#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
ROOT_FIX="$TMP_BASE/desktab-root-fix.sh"
RESOLV_FILE="$TMP_BASE/desktab-resolv.conf"

progress() {
  local pct="$1" eta="$2" stage="$3"
  mkdir -p "$STATE_DIR"
  printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$$" "$pct" "$eta" "$stage" > "$STATE_DIR/heartbeat.tmp"
  mv -f "$STATE_DIR/heartbeat.tmp" "$STATE_DIR/heartbeat"
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

command -v proot-distro >/dev/null 2>&1 || fail "데스크톱 수리 실패 · proot-distro 없음"
progress 92 12 "기존 Linux 환경 확인 · 재다운로드 없음"
if ! proot-distro login ubuntu --shared-tmp -- /bin/bash -lc \
  'test -x /usr/bin/xfce4-session && test -x /usr/bin/xfce4-terminal && command -v google-chrome-stable >/dev/null'; then
  fail "데스크톱 수리 대상 Ubuntu/Chrome 환경을 찾지 못했습니다"
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
# Do not reuse xfce4-terminal's D-Bus server in PRoot. A fresh process avoids the
# exo "Input/output error" path after a previous terminal window has been closed.
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

# Chrome may keep a background process after the last window closes. If it is
# genuinely alive, ask that process for a new window instead of starting a second
# profile owner. Ignore zombie processes because they cannot service a new window.
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
# Never restore stale Xfce client sessions from a killed PRoot session.
rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true

xfce4-session &
session_pid=$!

# xfconf becomes available shortly after the session starts. Disable compositing:
# software composition at tablet resolution wastes a large amount of CPU in PRoot.
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

if ! proot-distro login ubuntu --shared-tmp -- /bin/bash /tmp/desktab-root-fix.sh; then
  rm -f "$ROOT_FIX"
  fail "XFCE/Chrome 반복 실행 수리 실패"
fi
rm -f "$ROOT_FIX"

progress 97 4 "저지연 실행기 및 네트워크 설정"
cat > "$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
export XDG_RUNTIME_DIR="$TMP_BASE"

# Keep Termux runnable while Termux:X11 is the visible Android activity.
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

# Prefer Android's current DNS when it is exposed by the device. Public resolvers
# are only fallbacks; hardcoding one resolver can make browsing appear very slow.
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

exec proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  export PULSE_SERVER=127.0.0.1
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  if [ -s /tmp/desktab-resolv.conf ]; then
    cp -f /tmp/desktab-resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi

  # If the desktop is still alive, reuse it. This is the key difference from the
  # old launcher, which killed Xfce and Chrome every time the Android button was used.
  if pgrep -x xfce4-session >/dev/null 2>&1; then
    /usr/local/bin/desktab-chrome about:blank >/tmp/desktab-chrome-launch.log 2>&1 &
    exit 0
  fi

  # Remove only daemons left behind by a dead Xfce session, never a live session.
  pkill -x xfconfd >/dev/null 2>&1 || true
  pkill -x xfsettingsd >/dev/null 2>&1 || true
  pkill -x xfdesktop >/dev/null 2>&1 || true
  pkill -x xfce4-panel >/dev/null 2>&1 || true
  pkill -f "dbus-daemon.*--session" >/dev/null 2>&1 || true
  rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true
  exec dbus-launch --exit-with-session /usr/local/bin/desktab-xfce-session
'
LAUNCH
chmod 700 "$STATE_DIR/launch.sh"
printf '%s\n' '2' > "$STATE_DIR/desktop-repair-version"

progress 100 0 "데스크톱 반복 실행/성능 수리 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
exit 0
