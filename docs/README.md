# docs

| 파일 | 내용 | 누가 고치나 |
| --- | --- | --- |
| [webview-plan.md](webview-plan.md) | 웹뷰 앱 제작 계획. 옵시디언 노트 `whale-erp-staff/앱-출시/웹뷰-앱-제작-할일.md`의 사본이고, 개발자 계정 등록 내용만 뺐다. | 계획이나 결정이 바뀔 때만. 옵시디언 원본을 먼저 고치고 다시 복사한다 |
| [progress.md](progress.md) | 계획과 현재 코드를 비교한 결과, 다음에 할 일 | 앱 코드를 바꾸는 커밋마다 |

처음 계획은 Capacitor였고, 2026-11-19에 Flutter로 바꿨다. 계획서의 「이전 결정 — Capacitor」 절은 기록으로만 남긴 것이다.

## 커밋마다 분석하기

`lib/`, `android/`, `ios/`, `pubspec.yaml`, `assets/`를 바꾸는 커밋에는 `docs/progress.md` 갱신을 같이 넣는다.

1. 바뀐 코드를 `webview-plan.md`의 항목과 대조해 `progress.md`의 상태 표를 고친다.
2. "다음에 할 일" 순서를 다시 매긴다.
3. 맨 아래 "분석 기록"에 한 줄을 추가한다.

`.githooks/pre-commit`이 이 규칙을 검사한다. 앱 코드가 스테이징됐는데 `docs/progress.md`가 없으면 커밋을 막는다. 클론할 때 한 번 켜 준다. 설정은 그 클론의 모든 워크트리가 같이 쓴다. 다만 훅 파일(`.githooks/pre-commit`)은 워크트리마다 그 브랜치에 있어야 한다. 이 파일이 들어오기 전 커밋에서 갈라진 브랜치의 워크트리에서는 설정이 켜져 있어도 검사가 돌지 않는다.

먼저 쓰고 있는 훅이 있는지 확인한다. `core.hooksPath`는 훅을 추가하는 게 아니라 git이 훅을 찾는 폴더를 바꾸는 설정이라, 그대로 켜면 기존 훅(비밀정보 검사 등)이 돌지 않는다.

```bash
git config --get core.hooksPath     # 이미 다른 폴더를 쓰고 있는지
ls "$(git rev-parse --git-common-dir)/hooks" 2>/dev/null | grep -v '\.sample$'   # 기본 폴더에 직접 넣은 훅이 있는지 (폴더가 없어도 없는 것)
```

- 첫 줄이 `.githooks`를 출력하면 이미 켜진 상태다. 더 할 일이 없다.
- 둘 다 아무것도 출력하지 않으면 켠다.

  ```bash
  git config core.hooksPath .githooks
  ```

- 그 밖의 경우(다른 훅 폴더를 쓰고 있거나 기본 폴더에 훅이 있음)에는 켜지 않는다. 기존 훅을 어떻게 할지는 각자 판단한다.

분석이 필요 없는 커밋(오타, 주석만 고친 경우)은 이 검사만 건너뛴다.

```bash
SKIP_PROGRESS_CHECK=1 git commit ...
```

`git commit --no-verify`는 쓰지 않는다. 이 검사뿐 아니라 다른 훅(비밀정보 검사 등)까지 모두 건너뛴다.
