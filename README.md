# deskTAB Chrome

Android 기기에서 **Termux + Ubuntu + Termux:X11 + Linux 데스크톱용 Google Chrome**을 실행하기 위한 원클릭 런처입니다.

## 목표

- Termux와 Termux:X11 공식 APK 자동 다운로드 및 Android 설치 화면 호출
- Termux 안에 `proot-distro`와 Ubuntu 자동 설치
- Ubuntu 안에 XFCE, DBus, 한글/다국어 글꼴, 데스크톱 Google Chrome 자동 설치
- PulseAudio를 연결해 Linux Chrome의 오디오 출력 지원
- 이후 `deskTAB Chrome` 앱의 **Desktop Chrome 실행** 버튼만 눌러 다시 실행
- `main` 브랜치가 바뀔 때마다 GitHub Actions에서 APK 자동 빌드
- 빌드된 `deskTAB-Chrome.apk`를 Actions artifact로 자동 업로드

## 최초 사용

1. GitHub의 **Actions → Build Android APK → 최신 성공 실행 → Artifacts → deskTAB-Chrome-apk**에서 APK를 내려받아 설치합니다.
2. 앱에서 **1. 필수 앱 자동 설치**를 누릅니다. Termux와 Termux:X11은 공식 GitHub 릴리스에서 다운로드됩니다.
3. Android가 표시하는 APK 설치 확인은 직접 승인해야 합니다. Android 보안 정책상 앱이 다른 앱을 무인 설치할 수는 없습니다.
4. **2. Termux 연결 허용**을 누릅니다. 앱이 `allow-external-apps=true` 설정 명령을 클립보드에 복사합니다. 열리는 Termux에서 붙여넣고 Enter를 한 번 누릅니다.
5. deskTAB Chrome 앱의 추가 권한에서 **Run commands in Termux environment**를 허용합니다.
6. **3. Ubuntu + Chrome 자동 설정**을 누릅니다. 이후 Termux 패키지, Ubuntu, XFCE, 글꼴, Chrome 설치는 자동으로 진행됩니다.
7. 상태가 `설정 완료`로 바뀌면 **Desktop Chrome 실행**을 누릅니다.
8. 이후에는 Ubuntu/Chrome을 다시 설치할 필요 없이 앱에서 **Desktop Chrome 실행**만 누르면 됩니다.

## 왜 최초 1회 수동 단계가 필요한가

Termux는 외부 앱이 임의 명령을 실행하지 못하도록 `com.termux.permission.RUN_COMMAND` 권한과 `~/.termux/termux.properties`의 `allow-external-apps=true`를 모두 요구합니다. 이 보안 장치를 다른 앱이 스스로 우회하도록 만들지 않습니다.

Android 자체도 다른 APK의 무인 설치를 일반 앱에 허용하지 않으므로 Termux와 Termux:X11 설치 시 Android의 설치 확인 화면은 사용자가 승인해야 합니다.

## Chrome 실행 방식

Android → Termux → PRoot Ubuntu → XFCE → Termux:X11 → Google Chrome 순서로 실행됩니다. Chrome 프로필은 Ubuntu rootfs에 유지되므로 북마크, 확장 프로그램, 로그인 상태 등이 재실행 후에도 유지됩니다.

ARM64 Android에서는 Ubuntu `arm64`에 맞는 공식 `google-chrome-stable_current_arm64.deb`를 내려받습니다. AMD64 환경에서는 AMD64 패키지를 사용합니다.

PRoot에서는 Chrome의 일반 Linux sandbox가 정상 동작하지 않아 실행 시 `--no-sandbox`가 사용됩니다. 따라서 일반 데스크톱 PC의 Chrome과 UI/웹 기능은 매우 가깝지만 보안 격리, GPU 가속, 일부 USB/DRM/하드웨어 연동 기능까지 100% 동일하지는 않습니다.

## 지원 기기

- Android 8.0 이상
- **arm64-v8a 권장**
- x86_64 Android도 설치 코드상 지원
- 충분한 저장 공간 필요: Ubuntu + XFCE + Chrome 설치로 수 GB가 필요할 수 있습니다.

## GitHub Actions APK 빌드

`main` push 또는 수동 `workflow_dispatch` 시 `.github/workflows/build-apk.yml`이 실행됩니다.

Actions는 JDK 17, Android SDK 35, Gradle 8.9로 `:app:assembleDebug`를 수행하고 결과 APK를 `deskTAB-Chrome-apk` artifact로 30일간 보관합니다.

로컬에서는 다음 명령으로 같은 디버그 APK를 빌드할 수 있습니다.

```bash
gradle :app:assembleDebug
```
