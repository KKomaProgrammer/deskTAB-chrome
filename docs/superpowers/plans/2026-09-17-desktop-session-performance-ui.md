# deskTAB Desktop Session / Performance / UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make repeated Linux app launches reliable, reduce Chrome/X11 lag where possible, simplify Termux onboarding, and reduce the Android app to a one-button main screen plus settings.

**Architecture:** Preserve the current zstd runtime installer and rootfs data. Replace the post-install desktop repair/launch layer with a persistent session wrapper and stable XFCE helpers, then simplify the Android UI so setup and launch share one primary action while secondary controls move to settings.

**Tech Stack:** Android Java 17, Termux RUN_COMMAND/ContentProvider, Termux:X11, PRoot-Distro Ubuntu, XFCE, Bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-17-desktop-session-performance-ui-design.md`

## Global Constraints
- Do not delete or redownload an already-valid Ubuntu runtime.
- Keep existing zstd download/SHA/rollback behavior unchanged unless directly required by session repair.
- Keep ARM64 support and Android minSdk 26 / targetSdk 35.
- Use GitHub Termux + official Termux:X11 sharedUid build for performance.
- Main screen must not show implementation notes, update history, engine details, or multi-button setup clutter.

---

### Task 1: Persistent Linux desktop session repair

**Files:**
- Create: `installer/repair-v15.sh`
- Modify: `app/src/main/assets/bootstrap.sh`

**Interfaces:**
- Consumes: existing Ubuntu rootfs and `$HOME/.desktab` state.
- Produces: `$HOME/.desktab/launch.sh`, `/usr/local/bin/desktab-{terminal,file-manager,chrome,xfce-session}`, repaired XFCE helpers, and `desktop-repair-version=5`.

- [ ] **Step 1: Add session wrapper and helper self-tests**

Create wrappers that use `dbus-run-session` for a new desktop session, persist the session environment, configure `X-XFCE-Binaries`, and map Debian terminal aliases to the stable terminal wrapper.

- [ ] **Step 2: Make repeated launch reuse the session**

`launch.sh` starts Termux:X11 if needed, checks for a live XFCE session, sends a Chrome new-window request if live, otherwise starts the persistent desktop session. It must never kill a healthy XFCE session just to open Chrome.

- [ ] **Step 3: Verify shell syntax and rootfs-preserving behavior**

Run CI `bash -n` checks and invariant assertions for session wrapper, terminal helper, Chrome helper and no runtime deletion.

- [ ] **Step 4: Commit**

Commit message: `fix: make desktop app sessions persistent`

### Task 2: Performance-safe X11 and Chrome launch

**Files:**
- Modify: `installer/repair-v15.sh`
- Modify: `app/src/main/java/com/kkomaprogrammer/desktabchrome/SetupService.java` only if prerequisite download handling needs adjustment.

**Interfaces:**
- Consumes: official `termux-x11-nightly` companion and sharedUid Android APK.
- Produces: X11 launch using official startup path, compositor-off XFCE config, conservative Chrome flags, resolver fallback only when needed.

- [ ] **Step 1: Use X11 startup path and sharedUid-compatible setup**

Launch the graphical session via the Termux:X11 startup mechanism where possible and retain fallback behavior if unavailable.

- [ ] **Step 2: Remove forced GPU disable and tune Chrome conservatively**

Keep `--no-sandbox`, `--disable-dev-shm-usage`, limited renderer count and first-run suppression; remove unconditional `--disable-gpu` and retain a software fallback mode.

- [ ] **Step 3: Stop rewriting DNS on every launch**

Preserve distro resolver when usable and use Android DNS only if `/etc/resolv.conf` has no valid nameserver.

- [ ] **Step 4: Commit**

Commit message: `perf: reduce X11 and Chrome overhead`

### Task 3: Minimal Android UI and one-action onboarding

**Files:**
- Modify: `app/src/main/java/com/kkomaprogrammer/desktabchrome/MainActivity.java`
- Modify: `app/build.gradle`

**Interfaces:**
- Consumes: existing SetupService, RUN_COMMAND permission and setup SharedPreferences.
- Produces: one primary action button, gear-based secondary actions, compact progress/status, simplified Termux setup flow.

- [ ] **Step 1: Replace main layout**

Main UI contains title, compact status, progress only while active, one primary button and one gear button. Remove update notes and five stacked action buttons.

- [ ] **Step 2: Make primary action stateful**

If prerequisites are missing, start prerequisite flow. If Termux integration is not ready, launch compact connection flow. If Linux is not ready, run setup. If ready, launch Desktop Chrome.

- [ ] **Step 3: Move secondary actions to settings dialog**

Provide prerequisite install/repair, Termux connection, Linux repair, stop desktop and diagnostics in a settings dialog.

- [ ] **Step 4: Simplify first-time Termux setup**

Attempt normal permission/file bridge first; if Termux blocks it, copy the single required command and open Termux with concise instructions. Do not expose implementation details on main screen.

- [ ] **Step 5: Bump app version**

Set versionCode 24 and versionName `1.2.21`.

- [ ] **Step 6: Commit**

Commit message: `feat: simplify deskTAB launcher UI`

### Task 4: CI regression gates and release

**Files:**
- Modify: `.github/workflows/build-apk.yml`

**Interfaces:**
- Consumes: repaired shell scripts and Android sources.
- Produces: validated APK artifact and refreshed `apk-latest` release.

- [ ] **Step 1: Add regression assertions**

Assert repair-v15 syntax, persistent session strings, terminal helper binary metadata, no unconditional `--disable-gpu`, v1.2.21/versionCode 24, and minimal UI markers.

- [ ] **Step 2: Build APK**

Run `gradle --no-daemon :app:assembleDebug`.

- [ ] **Step 3: Verify artifact and release publication**

Confirm Actions success, artifact exists and `apk-latest` asset digest matches the built APK.

- [ ] **Step 4: Report installation path**

Provide APK and artifact ZIP; instruct update-in-place and one repair run only, with no Termux/rootfs deletion.