# deskTAB Chrome

Android 기기에서 **Termux + Ubuntu + Termux:X11 + Linux 데스크톱용 Google Chrome**을 실행하기 위한 런처입니다.

## v1.1.0

- Linux 환경 설정을 Android Foreground Service로 시작해 **deskTAB Chrome 앱을 닫아도 계속 진행**
- 설정 중 WakeLock을 사용해 화면이 꺼져도 장시간 설치 작업 유지
- 앱 화면과 지속 알림에 **단계별 진행률(%)**, 현재 작업, **예상 남은 시간** 표시
- 최초 전체 설정 예상 시간은 보통 **약 20~35분**으로 안내하며 기기/네트워크에 따라 달라짐
- Termux 및 Termux:X11 APK도 Foreground Service에서 다운로드해 **앱을 닫아도 다운로드 계속 진행**
- APK 다운로드는 실제 다운로드 바이트 기준으로 진행률 표시
- Termux 패키지 → Ubuntu rootfs → Ubuntu update → XFCE → 글꼴 → Chrome → 실행 구성 순으로 세부 단계 표시

## 최초 사용

1. Actions의 최신 성공 빌드에서 `deskTAB-Chrome-apk` artifact를 내려받아 APK를 설치합니다.
2. **1. 필수 앱 다운로드/설치**를 누릅니다. 다운로드는 백그라운드에서 계속됩니다.
3. 다운로드 완료 알림을 누른 뒤 Android의 Termux/Termux:X11 설치 화면을 승인합니다. Android 보안상 APK 무인 설치는 하지 않습니다.
4. **2. Termux 연결 허용**을 누릅니다. 복사된 명령을 Termux에서 한 번 실행하고 RUN_COMMAND 추가 권한을 허용합니다.
5. **3. Ubuntu + Chrome 백그라운드 설정**을 누릅니다.
6. 이제 앱을 닫거나 화면을 꺼도 설정이 계속되며 알림에서 진행률과 예상 시간을 확인할 수 있습니다.
7. 100%가 되면 앱에서 **Desktop Chrome 실행**을 누릅니다.

## 진행 단계

대략적인 가중치는 다음과 같습니다. 실제 시간은 네트워크 및 저장장치/CPU 성능에 따라 크게 달라질 수 있습니다.

- 2~12%: Termux 패키지 및 X11/proot/pulseaudio 준비
- 18~40%: Ubuntu rootfs 다운로드 및 설치
- 45~70%: Ubuntu 패키지 목록, XFCE, DBus, 글꼴 설치
- 78~92%: ARM64/AMD64 Linux용 Google Chrome 다운로드 및 설치
- 92~100%: Chrome 자동 실행 및 X11/PulseAudio 환경 구성

## 보안상 최초 1회 수동 단계

Android는 일반 앱이 다른 APK를 무인 설치하는 것을 허용하지 않습니다. 또한 Termux는 외부 앱 명령 실행에 `com.termux.permission.RUN_COMMAND`과 `allow-external-apps=true`를 요구합니다. 이 두 보안 확인은 자동 우회하지 않습니다.

## Chrome 실행 방식

Android → Termux → PRoot Ubuntu → XFCE → Termux:X11 → Google Chrome 순서입니다. Chrome 프로필은 Ubuntu rootfs에 유지되므로 북마크, 확장 프로그램, 로그인 상태가 재실행 후에도 유지됩니다.

PRoot 제약 때문에 Chrome은 `--no-sandbox`로 실행됩니다. 일반 PC와 UI/웹 기능은 매우 가깝지만 Chrome sandbox, GPU/USB/DRM 등 일부 저수준 기능은 동일하지 않습니다.

## GitHub Actions APK 빌드

`main`에 push하거나 `workflow_dispatch`를 실행하면 `.github/workflows/build-apk.yml`이 APK를 자동 빌드해 `deskTAB-Chrome-apk` artifact로 업로드합니다.
