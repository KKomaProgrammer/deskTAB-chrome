# deskTAB Desktop Session / Performance / UI Design

## Goal
Keep the already-working Linux download/install pipeline intact while making the installed desktop reliable for repeated app launches, reducing Chrome/X11 lag where technically possible, simplifying first-time Termux integration, and reducing the Android UI to the minimum needed for distribution.

## Architecture

### 1. Persistent desktop session
The Linux desktop gets one persistent D-Bus/XFCE session. `deskTAB` no longer relies on a chain of per-application `exo`/default-helper launches that can lose or recreate the session bus. A session wrapper writes its D-Bus environment and stays alive with XFCE; repeated Android launch requests reuse that session and request a Chrome window rather than tearing the desktop down.

Terminal, browser and file-manager helpers remain configured for XFCE compatibility, but they point to stable wrappers with complete `X-XFCE-Binaries` metadata. The terminal wrapper always starts a fresh `xfce4-terminal --disable-server` process. Standard Debian terminal aliases are also repaired so `Terminal=true` desktop entries do not depend solely on XFCE's preferred-application resolver.

### 2. Performance path
Use the official Termux:X11 sharedUid build with GitHub Termux. Start the graphical session through Termux:X11's `-xstartup` path where supported so Samsung/Android is less likely to classify the Linux workload as a background Termux process. Keep compositor disabled.

Do not force Chrome `--disable-gpu` unconditionally. Start with conservative Chrome flags that reduce renderer count and background work while allowing Chromium to select a usable graphics path; if GPU startup fails, a software fallback launcher remains available. Apply a lower X11 output resolution preference only through an explicit performance mode, with a safe default aimed at tablet use.

Do not overwrite `/etc/resolv.conf` on every launch. Preserve the distro resolver unless it is unusable; use Android-derived DNS only as a repair fallback.

### 3. First-time Termux setup
The Android app requests RUN_COMMAND normally. It attempts the safe automatic file/command bridge when Termux already permits external apps. Android/Termux intentionally blocks an external app from enabling `allow-external-apps=true` before that trust setting exists, so on affected first installs the app presents one compact action: copy the command and open Termux. No multi-step technical explanation is shown in the main screen.

### 4. Minimal Android UI
Main screen after installation: title, small status line, one large primary button (`Desktop Chrome 실행`), and a gear button. Before setup, the same primary button becomes `초기 설정 시작`.

The gear dialog contains only secondary actions: install/repair prerequisites, Termux connection, repair Linux, stop desktop, and diagnostics. Version history, implementation notes, long engine descriptions and explanatory paragraphs are removed from the main UI.

### 5. Safety / compatibility
Existing zstd runtime cache, installer validation, dpkg lock handling, download SHA validation, rollback and rootfs repair remain unchanged unless directly required by the session repair. Existing Ubuntu user data is not deleted. If a new session repair fails, the rootfs stays in place and the app reports a concise actionable state.

## Verification
CI must validate shell syntax, session wrapper/helper invariants, engine-version consistency, Android compilation, published runtime metadata and APK publication. Manual acceptance criteria: open Chrome, close it, reopen it; launch Terminal repeatedly; launch a Terminal=true desktop entry after other apps; keep Thunar working; re-enter deskTAB and reopen Chrome without restarting XFCE; verify setup/repair does not redownload Linux when a valid rootfs exists.