# WHALEERP 직원 앱 (whale-erp-staff-mobile-app)

직원용 모바일웹 [whale-erp-staff](../whale-erp-staff)를 웹뷰로 띄우는 Android·iOS 앱입니다.
화면은 웹이 그리고, 앱은 웹뷰를 감싸 뒤로가기, 외부 링크, 새로고침, 오류 화면, 스플래시 같은 네이티브 동작을 맡습니다.

| 항목 | 값 |
| --- | --- |
| 앱 이름 | WHALEERP |
| 번들 ID / applicationId | `kr.co.whaleerp.staff` |
| 플랫폼 | Android, iOS (iOS 15.0 이상, Android 최소 버전은 Flutter 기본값) |
| 화면 방향 | 세로 고정 |
| Dart SDK | `^3.13.2` |

## 주요 동작

코드는 `lib/main.dart` 한 파일에 있습니다.

- **웹 주소**: `--dart-define=WEB_URL=...`로 넘깁니다. 넘기지 않으면 dev 주소 `https://staff-dev.whaleerp.co.kr`를 띄웁니다.
- **링크 처리**: `WEB_URL`과 같은 호스트의 http(s) 주소만 앱 안에서 엽니다. 다른 도메인과 `tel:`, `mailto:` 링크는 외부 앱이나 브라우저로 엽니다.
- **Android 뒤로가기**: 웹 히스토리가 있으면 뒤로 가고, 없으면 앱을 종료합니다.
- **당겨서 새로고침**: 웹 화면을 아래로 당기면 다시 불러옵니다.
- **오류 화면**: 페이지를 불러오지 못하면 "연결할 수 없습니다" 화면과 "다시 시도" 버튼을 보여줍니다.
- **User-Agent**: 기본 User-Agent 끝에 `WhaleERPStaffApp`을 붙여서, 웹에서 앱 안에서 열렸는지 알 수 있습니다.
- **스플래시**: 정지된 OS 스플래시(`#0a0a0a` 바탕, 노란 고래)가 끝나면, 같은 화면 위에 고래를 감싸는 로딩 링을 띄웁니다. 첫 페이지가 그려지면 페이드 아웃합니다. 기기의 "동작 줄이기"가 켜져 있으면 링은 표시하지 않습니다.

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

`assets/`의 이미지는 모두 원본 `hf_20260820_080200_343cd9fa-537d-46c7-b869-1d87f4104b18.png`(2048×2048)에서 고래만 잘라 만들었습니다.

| 파일 | 용도 |
| --- | --- |
| `splash_logo.png` | OS 스플래시와 앱 안 스플래시 화면의 고래 (720px) |
| `splash_logo_android12.png` | Android 12 이상 스플래시 아이콘 (1152px 캔버스) |
| `app_icon.png` | iOS 앱 아이콘, Android 7 이하 아이콘 (1024px, 바탕 채움) |
| `app_icon_foreground.png` | Android 적응형 아이콘 전경과 테마 아이콘 (1024px, 투명 배경) |

스플래시 색이나 이미지를 바꾸면 `lib/main.dart`의 `splashColor`, `splashLogo`, `splashLogoSize`도 함께 맞춰야 합니다. 앱 안 스플래시 화면이 OS 스플래시와 같은 모습으로 이어져야 하기 때문입니다.

## 알아둘 점

- **prod 주소**: 아직 정해지지 않았습니다. 정해지면 `lib/main.dart`의 `WEB_URL` 기본값을 prod로 바꿔야 합니다(코드에 TODO가 있습니다).
- **릴리즈 서명**: Android release 빌드는 아직 debug 키로 서명됩니다(`android/app/build.gradle.kts`).
- **웹뷰 패키지 버전**: `flutter_inappwebview`는 `6.2.0-beta.3`으로 고정돼 있습니다. 6.1.5 안정판은 이 프로젝트가 쓰는 Android Gradle Plugin 9에서 빌드되지 않기 때문입니다. 6.2.0 안정판이 나오면 바꿀 예정입니다.
