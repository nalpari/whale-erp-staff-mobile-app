# WHALEERP 직원 앱 (whale-erp-staff-mobile-app)

직원용 모바일웹 [whale-erp-new-staff](https://github.com/nalpari/whale-erp-new-staff)를 웹뷰로 띄우는 Android·iOS 앱입니다.
화면은 웹이 그리고, 앱은 웹뷰를 감싸 뒤로가기, 외부 링크, 새로고침, 오류 화면, 스플래시 같은 네이티브 동작을 맡습니다.

| 항목 | 값 |
| --- | --- |
| 앱 이름 | 웨일ERP 직원 (iPhone 전용, 세로 고정) |
| 번들 ID / applicationId | `kr.co.whaleerp.staff` |
| 플랫폼 | Android, iOS (iOS 15.4 이상, Android 최소 버전은 Flutter 기본값) |
| 화면 방향 | 세로 고정 |
| Dart SDK | `^3.13.2` |

## 주요 동작

코드는 `lib/main.dart`에 있고, 웹과 주고받는 브리지는 `lib/native_bridge.dart`, 위치 측정은 `lib/location_reading.dart`에 따로 있습니다.

- **웹 주소**: `--dart-define=WEB_URL=...`로 넘깁니다. 넘기지 않으면 dev 주소 `https://staff-dev.whaleerp.co.kr`를 띄웁니다.
- **링크 처리**: `WEB_URL`과 같은 호스트의 http(s) 주소만 앱 안에서 엽니다. 다른 도메인과 `tel:`, `mailto:` 링크는 외부 앱이나 브라우저로 엽니다.
- **Android 뒤로가기**: 바텀시트가 열려 있으면 먼저 닫고, 없으면 웹 히스토리로 뒤로 가며, 그것도 없으면 앱을 종료합니다.
- **당겨서 새로고침**: 웹 화면을 아래로 당기면 다시 불러옵니다.
- **오류 화면**: 페이지를 불러오지 못하면 "연결할 수 없습니다" 화면과 "다시 시도" 버튼을 보여줍니다.
- **위치 권한**: 웹이 위치를 요청하면(출퇴근 화면) 그때 OS 위치 권한을 묻습니다. 앱 시작 때는 묻지 않습니다. Android는 웹 주소와 같은 https 출처의 요청만 허락합니다. 또 이미 「대략적 위치」로 허락돼 있으면 앱을 켠 동안 한 번 정확한 위치로 바꿀지 묻고(방금 그 창에서 대략적 위치를 골랐다면 바로 다시 묻지 않습니다), 대략적 위치 · 영구 거부 · 휴대폰 위치 꺼짐 · 권한 확인 실패면 화면 아래에 안내(설정으로 가는 버튼 포함)를 띄웁니다. iOS는 WKWebView가 OS 권한과 사이트 위치 확인 창을 직접 띄우며, 앱에서 출처를 검사하지 않고 정확한 위치 재요청과 안내도 없습니다.
- **웹 ↔ 앱 브리지**: 웹이 `window.flutter_inappwebview.callHandler`로 앱 기능을 부릅니다. 웹 주소와 같은 출처의 맨 위 화면에서 온 호출만 받습니다. 기능 목록과 답 형식은 [docs/native-bridge.md](docs/native-bridge.md)에 있습니다.
- **파일 받기**: 급여명세서 PDF와 근로계약서 파일은 앱이 받아 공유 시트로 엽니다(저장 · 카카오톡 전송 등). 급여 PDF는 웹 주소와 같은 출처일 때만 로그인 쿠키를 실어 받고, 계약서는 S3 서명 주소로 가는 이동을 가로채 쿠키 없이 받습니다.
- **User-Agent**: 기본 User-Agent 끝에 `WhaleStaffApp/<앱 버전>`(예: `WhaleStaffApp/1.0.0`)을 붙여서, 웹에서 앱 안에서 열렸는지 알 수 있습니다.
- **스플래시**: 정지된 OS 스플래시(남보라 `#4C4DDC` 바탕, 흰 고래와 별)가 끝나면, 같은 화면을 앱이 이어서 띄웁니다. 로딩 표시 없이 고래만 보이다가, 첫 페이지가 그려지면 페이드 아웃합니다.

## 실행과 빌드

```bash
flutter pub get
```

```bash
flutter run --dart-define=WEB_URL=https://staff-dev.whaleerp.co.kr
```

```bash
flutter build apk --release --dart-define=WEB_URL=https://staff-dev.whaleerp.co.kr
```

```bash
flutter build ios --simulator
```

iOS 빌드에는 Xcode와 CocoaPods가 필요합니다.

### 빌드된 APK 위치

`flutter build apk --debug`는 debug APK를, `flutter build apk --release`는 release APK를 만듭니다. 파일은 프로젝트 루트 기준으로 아래 경로에 생깁니다. 경로는 플랫폼과 상관없이 같고 구분자만 다릅니다.

| 플랫폼 | debug APK | release APK |
| --- | --- | --- |
| macOS | `build/app/outputs/flutter-apk/app-debug.apk` | `build/app/outputs/flutter-apk/app-release.apk` |
| Linux | `build/app/outputs/flutter-apk/app-debug.apk` | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows | `build\app\outputs\flutter-apk\app-debug.apk` | `build\app\outputs\flutter-apk\app-release.apk` |

같은 폴더에 체크섬 파일(`.apk.sha1`)도 함께 생깁니다. `flutter run`도 debug APK를 같은 경로에 다시 빌드해서 덮어씁니다.

검사와 테스트:

```bash
flutter analyze
```

```bash
flutter test
```

테스트는 링크 처리 규칙(`isInApp`)을 확인합니다.

## 스플래시와 앱 아이콘

둘 다 `pubspec.yaml`의 설정으로 생성합니다. 이미지나 색을 바꾼 뒤 아래 명령을 다시 실행하세요.

```bash
dart run flutter_native_splash:create
```

```bash
dart run flutter_launcher_icons
```

디자인은 남보라 `#4C4DDC` 바탕에 흰 고래입니다. 원본은 `assets/source/`(후보 A: `icon-a.png`, `splash-a.png`, `fg-solid.png`)에 있고 앱에는 묶이지 않습니다. 아래 파일은 이 원본에서 만들었습니다.

| 파일 | 용도 |
| --- | --- |
| `splash_logo.png` | OS 스플래시와 앱 안 스플래시 화면의 고래와 별 (720px) |
| `splash_logo_android12.png` | Android 12 이상 스플래시 아이콘 (1152px 캔버스) |
| `app_icon.png` | iOS 앱 아이콘, Android 7 이하 아이콘 (1024px, 바탕 채움) |
| `app_icon_foreground.png` | Android 적응형 아이콘 전경과 테마 아이콘 (1024px, 투명 배경) |

스플래시 색이나 이미지를 바꾸면 `lib/main.dart`의 `splashColor`, `splashLogo`, `splashLogoSize`도 함께 맞춰야 합니다. 앱 안 스플래시 화면이 OS 스플래시와 같은 모습으로 이어져야 하기 때문입니다.

## 알아둘 점

- **운영 주소**: `https://staff.whaleerp.co.kr`입니다. 도메인이 열리면 `lib/main.dart`의 `WEB_URL` 기본값을 운영으로 바꿔야 합니다(코드에 TODO가 있습니다).
- **릴리즈 서명**: Android release 빌드는 아직 debug 키로 서명됩니다(`android/app/build.gradle.kts`).
- **웹뷰 패키지 버전**: `flutter_inappwebview`는 `6.2.0-beta.3`으로 고정돼 있습니다. 6.1.5 안정판은 이 프로젝트가 쓰는 Android Gradle Plugin 9에서 빌드되지 않기 때문입니다. 6.2.0 안정판이 나오면 바꿀 예정입니다.
