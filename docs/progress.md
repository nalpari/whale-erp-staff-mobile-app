# 진행 현황 — 계획 대비 분석

계획: [webview-plan.md](webview-plan.md). 웹 저장소는 `whale-erp-new-staff`(계획서에서는 `whale-erp-staff`)다.

상태: ✅ 완료 · 🟡 일부 · ❌ 안 함 · ⚠️ 계획과 다름(결정 필요)

## 1. 계획과 다르게 간 것 — 먼저 정리할 것

계획서의 결정을 뒤집었거나 계획과 다르게 구현된 것들이다. 어느 쪽이 맞는지 정하고, 계획서나 코드 중 한쪽을 고친다.

| 항목 | 계획 | 현재 코드 | 할 일 |
| --- | --- | --- | --- |
| 껍데기 기술 | Capacitor (2026-11-13 결정) | Flutter + `flutter_inappwebview` 6.2.0-beta.3 | 바꾼 이유와 날짜를 계획서 결정 표에 남긴다. 브리지는 Capacitor 플러그인 대신 `addJavaScriptHandler` ↔ `window.flutter_inappwebview.callHandler`로 짠다 |
| 아이콘 · 스플래시 | 남보라 `#4C4DDC` 바탕에 흰 고래 (15번, 확정) | `#0a0a0a` 바탕에 노란 고래 `#f7fe57` | 새 시안으로 바꾼 것이면 계획서 15번을 고친다. 아니면 확정 시안으로 다시 만든다 |
| 앱 이름 | 「웨일ERP 직원」 (3번, 확정) | `WHALEERP` (Android `android:label`, iOS `CFBundleDisplayName`) | 확정 이름으로 바꾸거나 결정을 고친다 |
| 최소 OS | iOS 15+ · Android 8 (API 26)+ (4번, 확정) | iOS 15.0 ✅ · Android는 Flutter 기본값(24 = Android 7), 아이콘 설정도 `min_sdk_android: 24` | `android/app/build.gradle.kts`의 `minSdk = 26`으로 올린다 |
| 기기 범위 | 휴대전화 전용 (5번, 확정) | iOS `TARGETED_DEVICE_FAMILY = "1,2"` (iPad 포함) | `"1"`로 바꾼다. 안 바꾸면 iPad 스크린샷 · 심사 대응이 필요하다 |
| 번들 ID | 미정. 3단계 전까지는 임시 `com.temp.whalestaff` (2번) | `kr.co.whaleerp.staff` | 외부(Apple · Firebase · Play) 등록 전이라 아직 바꿀 수 있다. 이 값으로 확정할지 회의에서 정한다 |
| 운영 URL | `staff.whaleerp.co.kr` (6번, 확정) | 기본값 dev, 코드 TODO는 "prod 주소 미정" | 도메인이 열렸는지 확인한 뒤 TODO를 고친다 |
| 웹뷰 감지 UA | 예시 `WhaleStaffApp/1.0` | `WhaleERPStaffApp` (버전 없음) | 강제 업데이트(12번)에 쓰게 `WhaleERPStaffApp/<버전>`으로 바꾸는 것을 권장. 웹 쪽 감지 코드와 이름을 맞춘다 |

## 2. 계획 항목별 상태

### 네이티브 껍데기 (이 저장소)

| 항목 | 상태 | 근거 · 남은 일 |
| --- | --- | --- |
| 원격 URL 로드 · 환경 분리 | ✅ | `--dart-define=WEB_URL`. dev 기본값 |
| 외부 링크 | ✅ | `isInApp` + `url_launcher`, 단위 테스트 있음 |
| Android 뒤로 가기 | 🟡 | 웹 히스토리 → 앱 종료는 됨. 바텀시트(`<dialog>`) 먼저 닫기는 웹과 브리지로 맞춰야 한다 |
| 오프라인 · 오류 화면 | ✅ | `_ErrorView` + 다시 시도 |
| 스플래시 · 아이콘 · 상태바 | ✅ / ⚠️ | 동작은 끝. 디자인이 계획과 다르다(1절) |
| 키보드 | 🟡 | `adjustResize`는 있다. 하단 sticky Dock이 가리는지 실기기 확인이 남았다 |
| **위치 권한** | ❌ | 매니페스트에 위치 권한이 없고 iOS `NSLocationWhenInUseUsageDescription`도 없다. Android 웹뷰 `onGeolocationPermissionsShowPrompt`도 처리하지 않는다. **지금 앱에서는 출퇴근 위치를 못 잡는다** |
| 위치 조작 감지 (`isMock`) | ❌ | 네이티브 코드와 JS 핸들러가 둘 다 없다 |
| 파일 받기 (급여 PDF · 계약서) | ❌ | `onDownloadStartRequest` 처리가 없다. 공유 시트 연결이 필요하다 |
| 쿠키 유지 (자동 로그인 30일 / 7일) | 🟡 | 기본 동작에 맡겨 둔 상태. 앱을 백그라운드로 보낼 때 `CookieManager.flush()`를 부르지 않는다. 앱을 강제 종료한 뒤 로그인이 남는지 확인하지 않았다 |
| 기기 식별자 | ❌ | 네이티브 ID를 넘기는 핸들러가 없다 |
| 딥링크 (초대 · 비밀번호 재설정) | ❌ | intent-filter · Associated Domains가 없다. 번들 ID를 확정해야 시작할 수 있다 |
| 푸시 (FCM · APNs) | ❌ | api 팀과 토큰 등록 API 협의가 먼저다 |
| 강제 업데이트 | ❌ | api 팀과 최소 앱 버전 값 협의가 먼저다 |
| 당겨서 새로고침 | ⚠️ | 네이티브 `PullToRefreshController`를 켰다. 계획은 반대로 웹에서 오버스크롤을 끄는 것이었다. 서명 패드(`signature-pad.tsx`)에서 그리다가 새로고침이 되지 않는지 확인하고, 필요하면 해당 화면에서 끈다 |
| 릴리즈 서명 · iOS 프로비저닝 | ❌ | Android release가 debug 키로 서명된다. 이 맥에서는 iOS를 빌드해 본 적이 없다 |

### 웹 (`whale-erp-new-staff`, 로컬 `main` `ce1b1ee` 기준)

| 항목 | 상태 | 근거 |
| --- | --- | --- |
| viewport (`viewportFit`, `themeColor`) | ❌ | `src/app/layout.tsx`에 `export const viewport`가 없다. 앱은 Flutter `SafeArea`가 노치를 피하므로 급하지는 않다 |
| 웹뷰 감지 · 브리지 모듈 | ❌ | `WhaleERPStaffApp`를 감지하는 코드도, `native-bridge` 모듈도 없다 |
| 위치 조작 감지 연결 | ❌ | `check-in-screen.tsx`가 아직 `mocked: false`로 고정돼 있다 |
| 다운로드 · 뒤로 가기 브리지 | ❌ | 없음 |
| `assetlinks.json` · `apple-app-site-association` | ❌ | `public/`에 없다. 번들 ID를 확정한 뒤에 만든다 |

### 스토어 심사 · 정책

| 항목 | 상태 |
| --- | --- |
| Apple 4.2 최소 기능 (네이티브 기능 근거) | ❌ 지금은 순수 웹 래핑이다. 위치 · 파일 · 푸시가 붙어야 근거가 생긴다 |
| 앱 안 계정 삭제 (13번) | ❌ 정책 미정 |
| 개인정보 처리방침 · 고객지원 URL (14번) | ❌ 정책 미정 |
| 위치 권한 사유 문구 · Play 데이터 보안 양식 | ❌ |

## 3. 다음에 할 일

계획서의 진행 순서(1 껍데기 → 2 위치 · 파일 → 3 딥링크 → 4 푸시 → 5 스토어)로 보면 **1단계가 거의 끝났고 2단계는 시작 전**이다.

1. **1절 불일치 정리**: 기술(Flutter), 아이콘, 앱 이름, 번들 ID를 확정하고 계획서를 고친다. 이 중 minSdk 26과 iPhone 전용은 결정이 이미 나 있으니 바로 고친다
2. **1단계 마무리 확인**: 실기기에서 로그인 → 앱 강제 종료 → 재실행 후 로그인 유지(쿠키 flush), 키보드와 Dock, 서명 패드와 당겨서 새로고침 충돌
3. **위치 권한 (2단계, 최우선)**: Android 권한 + `onGeolocationPermissionsShowPrompt`, iOS 사유 문구. 출퇴근이 핵심 기능이라 이것 없이는 테스트를 못 한다
4. **JS 브리지 골격**: 앱에 `addJavaScriptHandler`, 웹에 `native-bridge.ts`. UA 이름과 버전을 함께 맞춘다
5. **위치 조작 감지**: 핸들러에서 `isMock` / `isSimulatedBySoftware`를 넘기고, 웹 `check-in-screen.tsx`의 `mocked`를 그 값으로 바꾼다
6. **파일 받기**: `onDownloadStartRequest` → 저장 후 공유 시트
7. 3단계 이후(딥링크 · 푸시 · 강제 업데이트)는 번들 ID 확정과 api 팀 협의가 먼저다. 협의 일정을 잡아 둔다

## 분석 기록

커밋마다 한 줄씩 추가한다. 형식: `날짜 · 분석 시점 HEAD · 바뀐 점 요약`

- 2026-11-19 · `79140e9` · 첫 분석. 1단계(껍데기 · 외부 링크 · 뒤로 가기 · 오류 화면 · 스플래시) 완료. 계획과 다른 점 8건(1절), 2단계 이후와 웹 연동은 전부 시작 전
