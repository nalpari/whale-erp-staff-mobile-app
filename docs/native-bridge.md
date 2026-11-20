# 앱 ↔ 웹 브리지 약속

웹(`whale-erp-new-staff`)이 앱 기능을 부르는 방법이다. 앱 쪽 구현은 `lib/native_bridge.dart`, 웹 쪽은 `src/lib/native-bridge.ts`(아직 없음)에 둔다.

## 앱 안인지 알아보기

- 앱은 User-Agent 끝에 `WhaleStaffApp/<앱 버전>`을 붙인다(예: `WhaleStaffApp/1.0.0`).
- 웹은 이 값으로 **앱 안인지 판별만** 한다. 권한 확인에 쓰지 않는다(누구나 흉내 낼 수 있다).

## 부르기

```js
// 브리지가 준비되면 window 에 이 이벤트가 온다. 이미 준비됐으면 window.flutter_inappwebview.callHandler 가 있다.
window.addEventListener("flutterInAppWebViewPlatformReady", () => { /* 준비됨 */ });

const result = await window.flutter_inappwebview.callHandler("appInfo");
```

- 인자는 `callHandler(이름, ...인자)`로 넘긴다. JSON으로 바꿀 수 있는 값만 넘긴다.

## 답

앱은 언제나 아래 둘 중 하나로 답한다.

| 모양 | 뜻 |
| --- | --- |
| `{ ok: true, data: ... }` | 성공. `data`는 기능마다 다르다 |
| `{ ok: false, error: "forbidden" }` | 앱이 받지 않는 호출. 웹 주소와 다른 출처(https · 호스트 · 포트), 또는 iframe 안에서 불렀다 |
| `{ ok: false, error: "failed" }` | 앱 기능이 실패했다. 자세한 내용은 앱 로그에만 남는다 |

- 앱에 없는 이름으로 부르면 앱까지 오지 않고 `null`이 돌아온다(웹뷰 플러그인 동작). 웹은 `null`도 실패로 다룬다.
- `forbidden`은 웹 코드 버그(iframe에서 부름 등)이거나 다른 사이트가 부른 것이다. 다시 시도하지 않는다.

## 기능 목록

| 이름 | 인자 | `data` | 쓰는 곳 |
| --- | --- | --- | --- |
| `appInfo` | 없음 | `{ version: "1.0.0", platform: "android" \| "ios" \| "other" }` | 브리지가 살아 있는지 확인, 앱 버전별로 기능 켜고 끄기 |

다음에 붙일 기능(계획서 순서): 위치 측정 · 조작 감지(다음 할 일 5), 파일 받기(6), 뒤로 가기 · 바텀시트 닫기.
