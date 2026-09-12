#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
STATE_DIR="$HOME/.desktab"
mkdir -p "$STATE_DIR"
CURRENT_STAGE="설정 시작"

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_STAGE="$*"
  /system/bin/am broadcast -a "$APP_PACKAGE.SETUP_PROGRESS" -p "$APP_PACKAGE" --ei progress "$pct" --el eta "$eta" --es stage "$CURRENT_STAGE" >/dev/null 2>&1 || true
}
failed() {
  local code=$?
  /system/bin/am broadcast -a "$APP_PACKAGE.SETUP_FAILED" -p "$APP_PACKAGE" --es stage "실패: $CURRENT_STAGE (exit $code)" >/dev/null 2>&1 || true
  exit "$code"
}
trap failed ERR

progress 2 1800 "Termux 패키지 목록 갱신"
pkg update -y
progress 6 1680 "Termux X11 저장소 준비"
pkg install -y x11-repo
progress 12 1500 "Termux 실행 구성요소 설치"
pkg install -y termux-x11-nightly proot-distro pulseaudio

if ! proot-distro list 2>/dev/null | grep -qE '^\s*ubuntu\s|ubuntu'; then
  progress 18 1320 "Ubuntu rootfs 다운로드 및 설치"
  proot-distro install ubuntu
else
  progress 40 960 "기존 Ubuntu 설치 확인 완료"
fi

progress 45 840 "Ubuntu 패키지 목록 갱신"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update'

progress 52 720 "XFCE 데스크톱 및 기본 구성요소 설치"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y xfce4 dbus-x11 ca-certificates curl wget gnupg xdg-utils'

progress 70 420 "한글·다국어 글꼴 설치"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y fonts-noto fonts-noto-cjk'

progress 78 300 "데스크톱 Google Chrome 확인"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
set -e
if ! command -v google-chrome-stable >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in arm64|amd64) ;; *) echo "Unsupported Chrome architecture: $ARCH" >&2; exit 40 ;; esac
  CHROME_DEB=/tmp/google-chrome-stable.deb
  curl -fL --retry 3 --connect-timeout 20 "https://dl.google.com/linux/direct/google-chrome-stable_current_${ARCH}.deb" -o "$CHROME_DEB"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$CHROME_DEB"
  rm -f "$CHROME_DEB"
fi
'

progress 92 120 "Chrome 실행 환경 구성"
proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
set -e
mkdir -p /root/.config/autostart /tmp/runtime-root
chmod 700 /tmp/runtime-root
cat >/root/.config/autostart/desktab-chrome.desktop <<"EOF"
[Desktop Entry]
Type=Application
Name=deskTAB Chrome
Comment=Desktop Google Chrome
Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --password-store=basic --start-maximized
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
'

progress 97 60 "원클릭 실행 스크립트 생성"
cat >"$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
export XDG_RUNTIME_DIR="$TMPDIR"
if ! pgrep -f "termux-x11 :1" >/dev/null 2>&1; then termux-x11 :1 >/dev/null 2>&1 & sleep 2; fi
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
export PULSE_SERVER=127.0.0.1
exec proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  export PULSE_SERVER=127.0.0.1
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  pkill -f google-chrome-stable >/dev/null 2>&1 || true
  pkill -f xfce4-session >/dev/null 2>&1 || true
  exec dbus-launch --exit-with-session xfce4-session
'
LAUNCH
chmod +x "$STATE_DIR/launch.sh"
touch "$STATE_DIR/ready"
progress 100 0 "설정 완료"
/system/bin/am broadcast -a "$APP_PACKAGE.SETUP_DONE" -p "$APP_PACKAGE" >/dev/null 2>&1 || true
