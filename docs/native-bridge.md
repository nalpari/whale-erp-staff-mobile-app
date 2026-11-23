# 앱 ↔ 웹 브리지 약속

웹(`whale-erp-new-staff`)이 앱 기능을 부르는 방법이다. 앱 쪽 구현은 `lib/native_bridge.dart`, 웹 쪽은 `src/lib/native-bridge.ts`(웹 PR #87)에 둔다. 한쪽을 바꾸면 이 문서와 다른 쪽을 같이 고친다.

## 앱 안인지 알아보기

- 앱은 기본 User-Agent 끝에 공백 하나를 두고 `WhaleStaffApp/<앱 버전>`을 붙인다(예: `... Mobile Safari/537.36 WhaleStaffApp/1.0.0`).
- 웹은 User-Agent **맨 앞이나 공백 바로 뒤**에 온 `WhaleStaffApp/`만 앱으로 본다(`NotWhaleStaffApp/1.0` 같은 다른 제품명은 앱이 아니다). 표식이 여럿이면 마지막 것을 버전으로 쓴다. 예전 표식 `WhaleERPStaffApp`은 앱으로 보지 않는다.
- 웹은 이 값으로 **앱 안인지 판별만** 한다. 권한 확인에 쓰지 않는다(누구나 흉내 낼 수 있다). 실제 허락은 앱이 출처와 맨 위 화면인지로 정한다.

## 브리지 준비

- 브리지가 준비되면 window에 `flutterInAppWebViewPlatformReady` 이벤트가 온다.
- 웹은 `window.flutter_inappwebview.callHandler`가 **함수로** 있으면 부를 수 있다고 본다. Android는 함수가 보여도 웹뷰가 문서 시작 스크립트를 지원하지 않으면 준비 이벤트 전에는 부를 수 없어서, 플러그인이 준비 이벤트 때 남기는 `window.flutter_inappwebview._platformReady === true`까지 본다. iOS는 이 표시가 없어도 함수가 보이면 부른다.
- 앱 안인데 준비가 안 됐으면 웹은 준비 이벤트를 **3초** 기다린다. 이벤트가 오지 않아도 그때 `callHandler` 함수가 있으면 불러 본다. 그래도 없으면 `unavailable`로 끝내고 웹 콘솔에 남긴다(앱 밖에서 열었을 때와 구분하려고).
- 앱 쪽에서 할 일은 없다. 플러그인(`flutter_inappwebview`)이 이벤트와 표시를 남긴다. 앱은 기능을 `onWebViewCreated`에서 등록해 페이지 스크립트보다 먼저 준비한다.

## 부르기

```js
const result = await window.flutter_inappwebview.callHandler("appInfo");
```

- 웹은 `callHandler`를 `src/lib/native-bridge.ts` 밖에서 부르지 않는다. 화면은 `callNative` · `getAppInfo` 같은 함수만 쓴다.
- 인자는 `callHandler(이름, ...인자)`로 넘긴다. JSON으로 바꿀 수 있는 값만 넘긴다.

## 답

앱은 언제나 아래 셋 중 하나로 답한다.

| 모양 | 뜻 |
| --- | --- |
| `{ ok: true, data: ... }` | 성공. **`data` 칸은 늘 넣는다.** 돌려줄 값이 없어도 `data: null`로 넣는다 |
| `{ ok: false, error: "forbidden" }` | 앱이 받지 않는 호출. 웹 주소와 다른 출처(https · 호스트 · 포트), 또는 iframe 안에서 불렀다 |
| `{ ok: false, error: "failed" }` | 앱 기능이 실패했다. 자세한 내용은 앱 로그에만 남는다 |

웹은 앱의 답을 아래 네 가지 실패로 나눠 다룬다.

| 웹이 받는 실패 | 언제 |
| --- | --- |
| `forbidden` | 앱이 `forbidden`으로 답했다. 웹 코드 버그(iframe에서 부름 등)이거나 다른 사이트가 부른 것이라 다시 시도하지 않는다 |
| `failed` | 앱이 `failed`로 답했거나, 호출이 예외로 끝났거나, **10초 안에 답이 없었다** |
| `unavailable` | 앱 밖이거나, 브리지가 없거나, 앱에 없는 기능이다. 앱에 없는 이름으로 부르면 앱까지 오지 않고 `null`이 돌아온다(웹뷰 플러그인 동작) |
| `malformed` | 앱의 답이 위 표와 다르다(`data` 칸이 없음, 모르는 오류 코드, `data` 모양이 기능 약속과 다름) |

## 시간 제한 (앱 기능을 만들 때 지킬 것)

- 웹은 호출마다 **10초**까지 기다리고, 넘으면 `failed`로 끝낸다. 앱이 그 뒤에 답해도 버려진다.
- 그래서 오래 걸릴 수 있는 기능(위치 권한 창, GPS 측정 등)은 **앱 안에서 10초보다 짧게 끝나도록** 시간 제한을 걸고, 넘으면 `failed`나 기능별 결과로 먼저 답한다.
- 시간 초과는 웹이 기다리기를 그만둔 것일 뿐 앱 기능은 계속 돌 수 있다. 부작용이 있는 기능(파일 저장 등)을 웹이 다시 부르면 두 번 실행될 수 있으니, 그런 기능은 다시 부르기 전에 결과를 따로 확인하게 만든다.

## 기능 목록

| 이름 | 인자 | `data` | 쓰는 곳 |
| --- | --- | --- | --- |
| `appInfo` | 없음 | `{ version: "1.0.0", platform: "android" \| "ios" \| "other" }` | 브리지가 살아 있는지 확인, 앱 버전별로 기능 켜고 끄기. 웹은 `platform`이 셋 밖의 값이면 `malformed`로 본다 |
| `measureLocation` | 없음 | 아래 「measureLocation」 | 출퇴근 탭 지도와 출근 · 퇴근 판정. 앱 안에서는 `navigator.geolocation` 대신 이것을 쓴다(계획 결정 8) |

### measureLocation

위치 권한을 확인하고(아직 정하지 않았으면 OS 권한 창을 띄우고), 지금 위치를 **새로** 한 번 재어 좌표와 모의 위치 여부를 **같은 측정값에서** 함께 돌려준다. 마지막으로 알던 위치는 쓰지 않는다. `data`는 웹 출퇴근 화면의 위치 상태와 같은 이름을 쓴다.

| `data.status` | 다른 칸 | 뜻 |
| --- | --- | --- |
| `"ok"` | `latitude`, `longitude`(도), `accuracyMeters`(미터), `mocked`(참 · 거짓), `precise`(참 · 거짓) | 위치를 쟀다. `mocked`는 운영체제가 알려 준 모의 위치 여부(Android `isMock` · `isFromMockProvider`, iOS `isSimulatedBySoftware`). `precise`가 거짓이면 Android 「대략적 위치」라 반경 판정이 틀릴 수 있다(판정은 그대로 하고, 앱이 화면 아래에 정확한 위치를 켜라는 안내를 띄운다) |
| `"denied"` | 없음 | 위치 권한 거부(영구 거부 포함). 영구 거부면 앱이 설정으로 가는 안내를 띄운다 |
| `"unavailable"` | `reason`: `"serviceDisabled"`(기기 위치 꺼짐) · `"permissionCheckFailed"`(권한 확인 실패) · `"timeout"`(8초 안에 위치를 못 읽음) · `"error"`(그 밖의 측정 오류) | 위치를 읽지 못했다. 기기 위치가 꺼졌으면 앱이 위치 설정으로 가는 안내를 띄운다 |

- **시간:** 권한 창이 뜨면 사용자가 고르는 동안 기다린다(앱 안 상한 60초). 권한이 정해진 뒤 측정은 앱 안에서 8초로 끊는다. 그래서 웹은 이 기능만 기본 10초 대신 **`timeoutMs: 75_000`** 처럼 길게 기다린다. 권한이 이미 있으면 보통 몇 초 안에 끝난다.
- **부작용 없음:** 다시 불러도 위치를 한 번 더 잴 뿐이다. 위치 수집 · 이용 확인자료는 웹이 지금처럼 서버에 남긴다(앱은 좌표를 저장하거나 서버로 보내지 않는다).
- **겹친 호출:** 권한 창이 떠 있는 동안 온 호출은 같은 권한 결과를 기다린다.

다음에 붙일 기능(계획서 순서): 파일 받기(다음 할 일 6), 뒤로 가기 · 바텀시트 닫기.
