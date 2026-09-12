#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
STATE_DIR="$HOME/.desktab"
mkdir -p "$STATE_DIR"

log() { printf '\n[deskTAB] %s\n' "$*"; }

log "Termux packages are being prepared..."
pkg update -y
pkg install -y x11-repo
pkg install -y termux-x11-nightly proot-distro pulseaudio

ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
if [ ! -d "$ROOTFS" ]; then
  log "Installing Ubuntu..."
  proot-distro install ubuntu
else
  log "Ubuntu is already installed."
fi

log "Installing XFCE and desktop Google Chrome inside Ubuntu..."
proot-distro login ubuntu --shared-tmp -- /bin/bash -s <<'UBUNTU_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y xfce4 dbus-x11 ca-certificates curl wget gnupg fonts-noto fonts-noto-cjk xdg-utils

if ! command -v google-chrome-stable >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    arm64|amd64) ;;
    *) echo "Unsupported Chrome architecture: $ARCH" >&2; exit 40 ;;
  esac

  CHROME_DEB="/tmp/google-chrome-stable.deb"
  CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_${ARCH}.deb"
  echo "Downloading desktop Google Chrome for $ARCH..."
  curl -fL --retry 3 --connect-timeout 20 "$CHROME_URL" -o "$CHROME_DEB"
  apt-get install -y "$CHROME_DEB"
  rm -f "$CHROME_DEB"
fi

mkdir -p /root/.config/autostart
cat >/root/.config/autostart/desktab-chrome.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=deskTAB Chrome
Comment=Desktop Google Chrome
Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --password-store=basic --start-maximized
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

mkdir -p /tmp/runtime-root
chmod 700 /tmp/runtime-root
UBUNTU_SETUP

cat >"$STATE_DIR/launch.sh" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
set -e
export XDG_RUNTIME_DIR="$TMPDIR"

if ! pgrep -f "termux-x11 :1" >/dev/null 2>&1; then
  termux-x11 :1 >/dev/null 2>&1 &
  sleep 2
fi

pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true

exec proot-distro login ubuntu --shared-tmp -- /bin/bash -lc '
  export DISPLAY=:1
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  pkill -f google-chrome-stable >/dev/null 2>&1 || true
  pkill -f xfce4-session >/dev/null 2>&1 || true
  exec dbus-launch --exit-with-session xfce4-session
'
LAUNCH
chmod +x "$STATE_DIR/launch.sh"

touch "$STATE_DIR/ready"
log "Setup complete. Return to deskTAB Chrome and tap Desktop Chrome launch."
/system/bin/am broadcast -a "$APP_PACKAGE.SETUP_DONE" -p "$APP_PACKAGE" >/dev/null 2>&1 || true
