# deskTAB Chrome

Android 기기에서 **Termux + Ubuntu + Termux:X11 + Linux 데스크톱용 Google Chrome**을 실행하는 런처입니다.

## v1.2 고속 설치

기존 방식은 Android 기기에서 Ubuntu를 내려받은 뒤 XFCE, 글꼴, Chrome과 수많은 의존 패키지를 `apt`로 하나씩 설치했습니다. 이 과정은 PRoot 특성상 파일 작업이 느려 20~30분 이상 걸릴 수 있고 진행률도 초반에 오래 정체될 수 있었습니다.

v1.2부터는 설치되는 데스크톱 환경과 기능을 유지하면서 구조를 바꿨습니다.

- GitHub Actions의 네이티브 ARM64 환경에서 Ubuntu 24.04 + XFCE + DBus + Noto/CJK 글꼴 + Google Chrome을 미리 구성
- 완성된 Linux rootfs를 압축하고 48MB 조각으로 나눠 배포
- Android에서는 여러 조각을 동시에 다운로드
- 실제 다운로드 바이트 기준으로 진행률과 예상 남은 시간 표시
- SHA-256 무결성 검사 후 압축을 바로 해제
- 기기에서 `apt install xfce4 ...`와 Chrome 의존 패키지 설치를 다시 수행하지 않음
- 중단된 조각은 이어받기
- 설치 후 압축 조각은 자동 삭제해 저장공간 회수
- 앱을 닫거나 화면을 꺼도 Foreground Service + WakeLock으로 계속 진행

**ARM64 기기의 목표 설치 시간은 약 2~5분입니다.** 실제 시간은 인터넷 연결과 저장장치 성능에 따라 달라질 수 있으므로 매우 느린 네트워크에서는 5분을 넘을 수 있습니다.

## 설치되는 구성

기존 기능을 유지합니다.

- Termux
- Termux:X11
- PRoot-Distro
- PulseAudio
- Ubuntu 24.04 ARM64
- XFCE 데스크톱
- DBus/X11 구성
- `fonts-noto`, `fonts-noto-cjk`
- `curl`, `wget`, `gnupg`, `xdg-utils`
- 공식 Linux ARM64 Google Chrome Stable
- Chrome 자동 시작 및 프로필 영구 저장
- Chrome 확장 프로그램 / DevTools / 북마크 / 로그인 데이터 유지

PRoot 특성상 Chrome은 `--no-sandbox`로 실행됩니다.

## 최초 사용

1. GitHub **Actions → Build Android APK → 최신 성공 실행 → Artifacts → deskTAB-Chrome-apk**에서 APK를 설치합니다.
2. **1. 필수 앱 다운로드/설치**를 누릅니다. Termux와 Termux:X11 APK 다운로드는 백그라운드에서 진행됩니다.
3. Android가 표시하는 APK 설치 화면을 승인합니다.
4. **2. Termux 연결 허용**을 누릅니다. 복사된 `allow-external-apps=true` 설정 명령을 Termux에 한 번 붙여넣고 Enter를 누릅니다.
5. deskTAB Chrome의 추가 권한에서 **Run commands in Termux environment**를 허용합니다.
6. **3. Ubuntu + Chrome 고속 설정**을 누릅니다.
7. 앱 화면과 알림에서 실제 진행률, 현재 단계, 예상 남은 시간을 확인할 수 있습니다. 앱을 닫아도 계속 설치됩니다.
8. 100%가 되면 **Desktop Chrome 실행**을 누릅니다.

v1.1에서 설치가 1% 부근에 정체된 상태였다면 v1.2 앱을 설치한 뒤 **Ubuntu + Chrome 고속 설정**을 다시 누르면 구형 설치 프로세스를 정리하고 새 고속 설치 엔진으로 전환합니다.

## 런타임 이미지 빌드

`.github/workflows/build-runtime.yml`은 `runtime/Dockerfile` 변경 시 ARM64 GitHub-hosted runner에서 사전 구성 이미지를 새로 만듭니다. 결과는 `runtime-image` 브랜치에 manifest와 분할 파일로 게시됩니다.

## APK 빌드

`main` 브랜치 push 또는 `workflow_dispatch` 시 `.github/workflows/build-apk.yml`에서 JDK 17, Android SDK 35, Gradle 8.9로 APK를 빌드합니다.

```bash
gradle :app:assembleDebug
```
