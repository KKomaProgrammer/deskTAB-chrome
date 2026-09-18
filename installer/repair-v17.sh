#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
TMP_BASE="${TMPDIR:-$PREFIX/tmp}"
HB_STATE="$STATE_DIR/repair-heartbeat-state"
HB_PID=""
mkdir -p "$STATE_DIR" "$TMP_BASE"

write_heartbeat() {
  local state tmp
  state="$(cat "$HB_STATE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$STATE_DIR/heartbeat.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$$" "$state" > "$tmp"
  mv -f "$tmp" "$STATE_DIR/heartbeat"
}
heartbeat_loop() { trap - ERR; set +e +E; while true; do write_heartbeat; sleep 2; done; }
stop_heartbeat() { set +e; [ -n "$HB_PID" ] && kill "$HB_PID" >/dev/null 2>&1 || true; }
trap stop_heartbeat EXIT
progress() {
  local p="$1" e="$2" s="$3" t="$HB_STATE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$p" "$e" "$s" > "$t"; mv -f "$t" "$HB_STATE"; write_heartbeat
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$p" --el eta "$e" --es stage "$s" >/dev/null 2>&1 || true
}
fail() {
  local m="$1"
  printf '%s\n' "$m" > "$STATE_DIR/repair-last-error"
  progress -1 0 "$m"
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" --es stage "$m" >/dev/null 2>&1 || true
  exit 1
}
unexpected() {
  local rc=$? line="${BASH_LINENO[0]:-?}"
  trap - ERR; set +e
  fail "데스크톱 수리 중 오류 · line $line · exit $rc"
}
trap unexpected ERR

find_root() {
  local r
  for r in "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"; do
    if [ -x "$r/usr/bin/bash" ] && [ -x "$r/usr/bin/xfce4-session" ] \
      && [ -x "$r/opt/google/chrome/google-chrome" ] && [ -f "$r/var/lib/dpkg/status" ]; then
      printf '%s\n' "$r"; return 0
    fi
  done
  return 1
}
raw_probe() {
  local root="$1"; shift
  command -v proot >/dev/null 2>&1 || return 127
  local -a a=(proot -0 -r "$root" -w /root -b /dev -b /proc -b /sys -b "$TMP_BASE:/tmp")
  local b; for b in /storage /sdcard /system /apex; do [ -e "$b" ] && a+=(-b "$b"); done
  "${a[@]}" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 "$@"
}

progress 91 15 "기존 Ubuntu/Chrome 직접 수리"
heartbeat_loop & HB_PID=$!
ROOT="$(find_root || true)"
[ -n "$ROOT" ] || fail "Ubuntu/Chrome rootfs를 찾지 못했습니다"
printf '%s\n' "$ROOT" > "$STATE_DIR/ubuntu-root-path"
rm -f "$STATE_DIR/repair-last-error"

progress 94 10 "데스크톱 실행 파일 직접 복구"
mkdir -p "$ROOT/usr/local/bin" "$ROOT/root/.local/share/applications" \
  "$ROOT/root/.local/share/xfce4/helpers" "$ROOT/root/.config/xfce4" \
  "$ROOT/root/.config/autostart" "$ROOT/root/.cache/sessions" "$ROOT/tmp/runtime-root" \
  || fail "94% · Ubuntu rootfs 쓰기 준비 실패"
chmod 700 "$ROOT/tmp/runtime-root" 2>/dev/null || true
if [ ! -e "$ROOT/usr/bin/google-chrome-stable" ] && [ ! -L "$ROOT/usr/bin/google-chrome-stable" ]; then
  ln -s /opt/google/chrome/google-chrome "$ROOT/usr/bin/google-chrome-stable" || fail "94% · Chrome 링크 복구 실패"
fi

cat > "$ROOT/usr/local/bin/desktab-terminal" <<'S'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
exec /usr/bin/xfce4-terminal --disable-server "$@"
S
cat > "$ROOT/usr/local/bin/desktab-file-manager" <<'S'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
exec /usr/bin/thunar "$@"
S
cat > "$ROOT/usr/local/bin/desktab-chrome" <<'S'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
[ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env
PROFILE="${HOME}/.config/google-chrome"; mkdir -p "$PROFILE" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
FLAGS=(--no-sandbox --disable-dev-shm-usage --password-store=basic --renderer-process-limit=3 --no-first-run --no-default-browser-check --start-maximized)
live=0
for pid in $(pgrep -f '/opt/google/chrome/google-chrome' 2>/dev/null); do
  st="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"; case "$st" in Z*|'') ;; *) live=1; break;; esac
done
[ "$live" -eq 0 ] && rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
[ "${DESKTAB_SOFTWARE_RENDERING:-0}" = "1" ] && FLAGS+=(--disable-gpu)
exec /usr/bin/google-chrome-stable "${FLAGS[@]}" --new-window "${1:-about:blank}"
S
cat > "$ROOT/usr/local/bin/desktab-xfce-inner" <<'S'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}" PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
umask 077
{
  printf 'export DISPLAY=%q\n' "$DISPLAY"
  printf 'export XDG_RUNTIME_DIR=%q\n' "$XDG_RUNTIME_DIR"
  printf 'export DBUS_SESSION_BUS_ADDRESS=%q\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
  printf 'export PULSE_SERVER=%q\n' "$PULSE_SERVER"
} > /tmp/desktab-session.env
xfce4-session & p=$!
for _ in $(seq 1 40); do
  if pgrep -x xfconfd >/dev/null 2>&1; then xfconf-query -c xfwm4 -p /general/use_compositing -s false >/dev/null 2>&1 || true; break; fi
  sleep 0.15
done
wait "$p"; rm -f /tmp/desktab-session.env
S
cat > "$ROOT/usr/local/bin/desktab-xfce-session" <<'S'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:1}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}" PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
rm -rf "$HOME/.cache/sessions"/* 2>/dev/null || true; rm -f /tmp/desktab-session.env
if command -v dbus-run-session >/dev/null 2>&1; then exec dbus-run-session -- /usr/local/bin/desktab-xfce-inner; fi
exec dbus-launch --exit-with-session /usr/local/bin/desktab-xfce-inner
S
chmod 755 "$ROOT/usr/local/bin/desktab-"* || fail "94% · 실행 파일 권한 설정 실패"
ln -sf /usr/local/bin/desktab-terminal "$ROOT/usr/local/bin/x-terminal-emulator" || true

cat > "$ROOT/root/.local/share/xfce4/helpers/custom-TerminalEmulator.desktop" <<'S'
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
S
cat > "$ROOT/root/.local/share/xfce4/helpers/custom-WebBrowser.desktop" <<'S'
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
S
cat > "$ROOT/root/.local/share/xfce4/helpers/custom-FileManager.desktop" <<'S'
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
S
cat > "$ROOT/root/.config/xfce4/helpers.rc" <<'S'
WebBrowser=custom-WebBrowser
FileManager=custom-FileManager
TerminalEmulator=custom-TerminalEmulator
S
cat > "$ROOT/root/.local/share/applications/google-chrome.desktop" <<'S'
[Desktop Entry]
Version=1.0
Name=Google Chrome
Exec=/usr/local/bin/desktab-chrome %U
Terminal=false
Type=Application
Icon=google-chrome
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=false
S
cat > "$ROOT/root/.local/share/applications/xfce4-terminal.desktop" <<'S'
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
S
cat > "$ROOT/root/.config/autostart/desktab-chrome.desktop" <<'S'
[Desktop Entry]
Type=Application
Name=deskTAB Chrome
Exec=/usr/local/bin/desktab-chrome
Terminal=false
X-GNOME-Autostart-enabled=true
S
cat > "$ROOT/root/.config/mimeapps.list" <<'S'
[Default Applications]
text/html=google-chrome.desktop
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
inode/directory=thunar.desktop
S

progress 96 6 "Ubuntu 실행 경로 확인"
PD_OK=0
if command -v proot-distro >/dev/null 2>&1; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'test -x /usr/local/bin/desktab-xfce-session && test -x /usr/local/bin/desktab-chrome' >/dev/null 2>&1
  else
    proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'test -x /usr/local/bin/desktab-xfce-session && test -x /usr/local/bin/desktab-chrome' >/dev/null 2>&1
  fi
  [ "$?" -eq 0 ] && PD_OK=1
  set -e
fi
if [ "$PD_OK" -eq 0 ]; then
  raw_probe "$ROOT" /bin/bash -lc 'test -x /usr/local/bin/desktab-xfce-session && test -x /usr/local/bin/desktab-chrome' >/dev/null 2>&1 \
    || fail "96% · Ubuntu 실행 확인 실패 · rootfs는 보존됨"
fi
MODE=raw; [ "$PD_OK" -eq 1 ] && MODE=proot-distro
printf -v RQ '%q' "$ROOT"; printf -v TQ '%q' "$TMP_BASE"; printf -v MQ '%q' "$MODE"

cat > "$STATE_DIR/guest-exec.sh" <<EOF_G
#!/data/data/com.termux/files/usr/bin/bash
set +e
ROOT=$RQ
TMP_BASE=$TQ
MODE=$MQ
if [ "\$MODE" = proot-distro ]; then exec proot-distro login ubuntu --shared-tmp -- "\$@"; fi
args=(proot -0 -r "\$ROOT" -w /root -b /dev -b /proc -b /sys -b "\$TMP_BASE:/tmp")
for b in /storage /sdcard /system /apex; do [ -e "\$b" ] && args+=(-b "\$b"); done
exec "\${args[@]}" /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM="\${TERM:-xterm-256color}" LANG=C.UTF-8 "\$@"
EOF_G
cat > "$STATE_DIR/xstartup.sh" <<'S'
#!/data/data/com.termux/files/usr/bin/bash
set +e
exec "$HOME/.desktab/guest-exec.sh" /bin/bash -lc 'export DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-root PULSE_SERVER=127.0.0.1; exec /usr/local/bin/desktab-xfce-session'
S
cat > "$STATE_DIR/open-chrome.sh" <<'S'
#!/data/data/com.termux/files/usr/bin/bash
set +e
exec "$HOME/.desktab/guest-exec.sh" /bin/bash -lc 'export DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-root PULSE_SERVER=127.0.0.1; [ -r /tmp/desktab-session.env ] && . /tmp/desktab-session.env; exec /usr/local/bin/desktab-chrome about:blank'
S
chmod 700 "$STATE_DIR/guest-exec.sh" "$STATE_DIR/xstartup.sh" "$STATE_DIR/open-chrome.sh"

cat > "$STATE_DIR/launch.sh" <<'S'
#!/data/data/com.termux/files/usr/bin/bash
set +e
D="$HOME/.desktab"; T="${TMPDIR:-$PREFIX/tmp}"; X="$T/.X11-unix/X1"; S="$D/desktop-status"; L="$D/desktop-launch.lock"
mkdir -p "$D" "$T/.X11-unix"; export XDG_RUNTIME_DIR="$T"; termux-wake-lock >/dev/null 2>&1 || true
st(){ printf '%s|%s\n' "$(date +%s)" "$1" > "$S"; }
if ! mkdir "$L" 2>/dev/null; then o="$(cat "$L/pid" 2>/dev/null || true)"; [ -n "$o" ] && kill -0 "$o" 2>/dev/null && exit 0; rm -rf "$L"; mkdir "$L" 2>/dev/null || exit 0; fi
echo $$ > "$L/pid"; trap 'rm -rf "$L"' EXIT
waitx(){ for _ in $(seq 1 80); do [ -S "$X" ] && return 0; sleep .1; done; return 1; }
ensurex(){
  /system/bin/am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
  pgrep -f '[t]ermux-x11 :1' >/dev/null 2>&1 && [ -S "$X" ] && return 0
  pkill -x termux-x11 >/dev/null 2>&1 || true
  rm -f "$X" "$T/.X1-lock"
  termux-x11 :1 >"$D/x11.log" 2>&1 &
  waitx && return 0
  pkill -x termux-x11 >/dev/null 2>&1 || true
  rm -f "$X" "$T/.X1-lock"
  termux-x11 :1 -legacy-drawing >"$D/x11.log" 2>&1 &
  waitx
}
alive(){ [ -s "$T/desktab-session.env" ] && "$D/guest-exec.sh" /bin/bash -lc 'pgrep -x xfce4-session >/dev/null 2>&1' >/dev/null 2>&1; }
starts(){
  rm -f "$T/desktab-session.env"; "$D/guest-exec.sh" /bin/bash -lc 'pkill -x xfce4-session >/dev/null 2>&1 || true; pkill -x xfconfd >/dev/null 2>&1 || true; pkill -x xfsettingsd >/dev/null 2>&1 || true; pkill -x xfdesktop >/dev/null 2>&1 || true; pkill -x xfce4-panel >/dev/null 2>&1 || true; pkill -f "[d]esktab-xfce-session" >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
  command -v setsid >/dev/null 2>&1 && setsid "$D/xstartup.sh" >"$D/session.log" 2>&1 </dev/null & || nohup "$D/xstartup.sh" >"$D/session.log" 2>&1 </dev/null &
}
ensures(){ alive && return 0; starts; for _ in $(seq 1 80); do alive && return 0; sleep .15; done; return 1; }
st 'START|X11 준비'; ensurex || { st 'FAIL|X11 서버 시작 실패'; exit 81; }
command -v termux-x11-preference >/dev/null 2>&1 && timeout 2 termux-x11-preference displayResolutionMode=scaled displayScale=60 fullscreen=true >/dev/null 2>&1 || true
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
st 'START|XFCE 준비'; ensures || { pkill -x termux-x11 >/dev/null 2>&1 || true; rm -f "$X" "$T/.X1-lock" "$T/desktab-session.env"; ensurex && ensures || { st 'FAIL|XFCE 세션 시작 실패'; exit 82; }; }
st 'OK|Desktop Chrome 실행'; command -v setsid >/dev/null 2>&1 && setsid "$D/open-chrome.sh" >"$D/chrome-launch.log" 2>&1 </dev/null & || nohup "$D/open-chrome.sh" >"$D/chrome-launch.log" 2>&1 </dev/null &
exit 0
S
cat > "$STATE_DIR/stop.sh" <<'S'
#!/data/data/com.termux/files/usr/bin/bash
set +e
D="$HOME/.desktab"; "$D/guest-exec.sh" /bin/bash -lc 'pkill -x chrome >/dev/null 2>&1 || true; pkill -x google-chrome >/dev/null 2>&1 || true; pkill -x xfce4-session >/dev/null 2>&1 || true; pkill -f "[d]esktab-xfce-session" >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
pkill -x termux-x11 >/dev/null 2>&1 || true; T="${TMPDIR:-$PREFIX/tmp}"; rm -f "$T/.X11-unix/X1" "$T/.X1-lock" "$T/desktab-session.env"; rm -rf "$D/desktop-launch.lock"; /system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
S
chmod 700 "$STATE_DIR/launch.sh" "$STATE_DIR/stop.sh"
for f in "$STATE_DIR/guest-exec.sh" "$STATE_DIR/xstartup.sh" "$STATE_DIR/open-chrome.sh" "$STATE_DIR/launch.sh" "$STATE_DIR/stop.sh"; do bash -n "$f" || fail "96% · 실행기 검사 실패: $(basename "$f")"; done
printf '%s\n' 10 > "$STATE_DIR/desktop-repair-version"; printf '%s\n' 11 > "$STATE_DIR/engine-version"; touch "$STATE_DIR/ready"
progress 100 0 "Desktop Chrome 준비 완료"
/system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_DONE" >/dev/null 2>&1 || true
exit 0
