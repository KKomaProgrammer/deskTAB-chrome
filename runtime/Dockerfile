FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
LABEL org.opencontainers.image.source="https://github.com/KKomaProgrammer/deskTAB-chrome"
LABEL org.opencontainers.image.description="Prebuilt Ubuntu + XFCE + Google Chrome runtime for deskTAB Chrome"

RUN apt-get update \
 && apt-get install -y xfce4 dbus-x11 ca-certificates curl wget gnupg xdg-utils fonts-noto fonts-noto-cjk \
 && ARCH="$(dpkg --print-architecture)" \
 && test "$ARCH" = "arm64" \
 && curl -fL --retry 4 --connect-timeout 20 \
      "https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb" \
      -o /tmp/google-chrome.deb \
 && apt-get install -y /tmp/google-chrome.deb \
 && rm -f /tmp/google-chrome.deb \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/*

RUN mkdir -p /root/.config/autostart /tmp/runtime-root \
 && chmod 700 /tmp/runtime-root \
 && printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    'Name=deskTAB Chrome' \
    'Comment=Desktop Google Chrome' \
    'Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --password-store=basic --start-maximized' \
    'Terminal=false' \
    'X-GNOME-Autostart-enabled=true' \
    > /root/.config/autostart/desktab-chrome.desktop
