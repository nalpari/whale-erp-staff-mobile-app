# docs

| 파일 | 내용 | 누가 고치나 |
| --- | --- | --- |
| [webview-plan.md](webview-plan.md) | 웹뷰 앱 제작 계획 원본. 옵시디언 노트 `whale-erp-staff/앱-출시/웹뷰-앱-제작-할일.md`(2026-11-17판)를 옮긴 것이다. 개발자 계정 등록 내용은 뺐다. | 계획이나 결정이 바뀔 때만 |
| [progress.md](progress.md) | 계획과 현재 코드를 비교한 결과, 다음에 할 일 | 앱 코드를 바꾸는 커밋마다 |

`webview-plan.md`는 **Capacitor를 쓰기로 했던 시점**의 문서다. 실제로는 Flutter(`flutter_inappwebview`)로 만들었으므로, 계획에 있는 Capacitor 전용 내용(`capacitor.config.ts`, `@capacitor/assets`, 공식 플러그인 이름)은 `progress.md`에서 Flutter 기준으로 바꿔 읽는다.

## 커밋마다 분석하기

`lib/`, `android/`, `ios/`, `pubspec.yaml`, `assets/`를 바꾸는 커밋에는 `docs/progress.md` 갱신을 같이 넣는다.

1. 바뀐 코드를 `webview-plan.md`의 항목과 대조해 `progress.md`의 상태 표를 고친다.
2. "다음에 할 일" 순서를 다시 매긴다.
3. 맨 아래 "분석 기록"에 한 줄을 추가한다.

`.githooks/pre-commit`이 이 규칙을 검사한다. 앱 코드가 스테이징됐는데 `docs/progress.md`가 없으면 커밋을 막는다. 클론이나 워크트리를 새로 만들면 한 번 켜 준다.

```bash
git config core.hooksPath .githooks
```

분석이 필요 없는 커밋(오타, 주석만 고친 경우)은 `git commit --no-verify`로 건너뛴다.
