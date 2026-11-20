# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter (Android + iOS only) WebView shell for the staff mobile web app `whale-erp-new-staff` (Next.js, sibling repo `../whale-erp-new-staff`; older notes call it `whale-erp-staff`). The app itself has almost no UI: it loads the web app full screen and adds native glue (back button, external links, pull-to-refresh, error/retry, splash). Bundle ID `kr.co.whaleerp.staff`, display name 「웨일ERP 직원」, iPhone only (`TARGETED_DEVICE_FAMILY = "1"`), portrait only.

## Commands

```bash
flutter pub get
flutter analyze
flutter test                                              # all tests
flutter test test/widget_test.dart --plain-name '다른 호스트'   # single test by name substring
flutter run --dart-define=WEB_URL=https://staff-dev.whaleerp.co.kr
flutter build apk --release --dart-define=WEB_URL=...     # release is signed with debug keys for now
flutter build ios --simulator                              # needs full Xcode + CocoaPods
dart run flutter_native_splash:create                      # after changing the flutter_native_splash block
dart run flutter_launcher_icons                            # after changing the flutter_launcher_icons block
```

`WEB_URL` defaults to the dev URL (`https://staff-dev.whaleerp.co.kr`) in `lib/main.dart`; the prod URL is `https://staff.whaleerp.co.kr`, and the TODO says to switch the default once its DNS is live (not yet as of 2026-11-19). dev/prod are one app ID switched by the define, not flavors.

Local Android tooling on this machine: SDK at `/opt/homebrew/share/android-commandlinetools` (adb/emulator are not on PATH; use `platform-tools/adb`, `emulator/emulator`). AVD `whale_pixel` (Pixel 7, Android 16) lives in `~/.android/avd`. `avdmanager` from the Homebrew `cmdline-tools/latest` (v22) cannot create AVDs for the API 36 image; use `cmdline-tools/latest-2` (v23). `flutter run` here has failed to attach DDS after launch; the installed app still runs.

## Worktrees and branches

Create worktrees with Orca, not Claude Code's `EnterWorktree` (that one lands in `.claude/worktrees/`, which Orca does not register, so it shows up as a folder inside `main`). Follow the same naming as the other WHALEERP repos (`whale-erp-api`, `whale-erp-new-front`, `whale-erp-new-staff`): one lowercase English Pokémon name, with no `chang-su98/` prefix, used for both the worktree and the branch (`togepi`, `gengar`). Orca's default prefixes the git username and picks a random word (for example `chang-su98/pacu`), so always pass `--branch`. The `--repo` path below is this machine's main checkout; on another machine use that clone's path (`git rev-parse --show-toplevel` from the main checkout):

```bash
orca worktree create --repo path:/Users/kcs/workspace/WHALEERP/whale-erp-staff-mobile-app --name togepi --branch togepi --no-parent --json
```

Replace `togepi` in both `--name` and `--branch` with the new name.

Pick a name that is not already a branch here (`git branch -a`). Ticket-scoped branches like `WHALEERP-659-contract-status-names` also exist in the other repos; use that form only when the work is tied to a Plane issue.

## Plan tracking (every commit)

`docs/webview-plan.md` is the plan, a copy of the user's Obsidian note `ObsidianNew/whale-erp-staff/앱-출시/웹뷰-앱-제작-할일.md` (vault `/Users/kcs/김창수/obsidian`) without the developer-account link. Flutter replaced the original Capacitor choice on 2026-11-19. `docs/progress.md` compares that plan against the code and lists what to do next.

Any commit that touches `lib/`, `android/`, `ios/`, `assets/` or `pubspec.yaml` must include an updated `docs/progress.md`: re-check the changed items against the plan, update the status tables and the "다음에 할 일" order, and append one line to "분석 기록" (`date · HEAD at analysis time · summary`). When splitting work into several commits, update it in each app-code commit. `.githooks/pre-commit` enforces this; enable it per clone with `git config core.hooksPath .githooks` (it replaces the hooks directory, so check for existing hooks first; see `docs/README.md`). Do not bypass it unless the user asks; if they do, use `SKIP_PROGRESS_CHECK=1 git commit ...`, which skips only this check, never `--no-verify` (that skips every hook).

If a plan decision changes (tech, icon, name, bundle ID), edit the Obsidian note first, note the date, then re-copy it to `docs/webview-plan.md` (drop the `관련: [[개발자-계정-등록-...]]` line) so the two do not drift.

## Architecture

Everything lives in `lib/main.dart`.

- `isInApp(uri, base)` is the navigation rule: same host as `WEB_URL` over http(s), or webview-internal schemes (`about`, `data`, `blob`, `javascript`), stay in the webview. Everything else (other hosts, `tel:`, `mailto:`) is cancelled in `shouldOverrideUrlLoading` and opened with `url_launcher` externally. It, `appUserAgent` and `readAppVersion` are the unit-tested functions (`test/widget_test.dart`); the webview itself is not testable in widget tests.
- `WebScreen` wraps the `InAppWebView`: `PopScope` maps Android back to webview history, then `SystemNavigator.pop()`. A main-frame load error (except `CANCELLED`) shows `_ErrorView`. User-Agent gets `WhaleStaffApp/<version>` appended (`appUserAgent`, version from `package_info_plus` read in `main()` before `runApp` via `readAppVersion`, which falls back to `unknown` on error or a 2 s timeout because `main()` holds the first frame while it waits) so the web app can detect the shell. It is for detection only, never for authorization.

### Two-stage splash (the subtle part)

The OS splash (generated by `flutter_native_splash`) is static, so `SplashOverlay` draws an identical screen in Flutter on top of the webview while the first page loads, then fades out. The handoff only looks seamless if these invariants hold:

- `splashColor`, `splashLogo`, `splashLogoSize` in `main.dart` must match the `flutter_native_splash` block in `pubspec.yaml`. The 720px `assets/splash_logo.png` is treated as 4x by the package, hence 180dp. The overlay sits outside `SafeArea` so it is centered on the full screen like the OS splash.
- `main()` calls `deferFirstFrame()` and `SplashOverlay` calls `allowFirstFrame()` only after `precacheImage`, so the first Flutter frame never shows the background without the whale.
- `MainActivity.kt` removes the Android 12+ system splash with no exit animation (`setOnExitAnimationListener { it.remove() }`); the default animation fades the icon out first and breaks the handoff.
- The overlay hides only after `onLoadStop` plus two `requestAnimationFrame`s inside the page; `onLoadStop` alone fires before the page paints and exposes a blank white webview.
- There is no loading indicator on the overlay (removed 2026-11-20 at the user's request); it is the static whale until the page paints. An earlier spinning ring had to be added only after the webview attached (`onWebViewCreated` + `endOfFrame`), because rendering it before the platform view joined composition caused one-frame flashes on the emulator. Keep that in mind if an indicator comes back.
- `AnnotatedRegion` sets light status-bar icons over the indigo overlay and dark icons over the web content.

### Image assets

Design: white whale on indigo `#4C4DDC` (= `primary`). The chosen originals (candidate set A, 2026-11-20) live in `assets/source/` (`icon-a.png`, `splash-a.png`, `fg-solid.png`); they are not bundled (only `splash_logo.png` is listed under `flutter: assets`). Their painted backgrounds are slightly noisy and a touch off `#4C4DDC` (about `#4849DA` / `#4A4BD5`), so the solid colors in `pubspec.yaml` use `#4C4DDC`. The derived PNGs were produced with one-off Python/PIL scripts that are not in the repo:

- `app_icon.png` is `icon-a.png` copied as is.
- `splash_logo*.png`: alpha from the projection of each pixel onto (white − splash background color), RGB white, whale + stars cropped to their bounding box, scaled so the box diagonal is 720px, centered.
- `app_icon_foreground.png`: `fg-solid.png` with alpha ≤ 16 noise cleared to 0, RGB white.

| File | Use | Geometry |
| --- | --- | --- |
| `splash_logo.png` | OS splash + Flutter overlay | 720px, whale + stars box diagonal = 720px |
| `splash_logo_android12.png` | Android 12+ splash icon | 1152px canvas, same 720px-diagonal logo centered (inside the 768px masked circle) |
| `app_icon.png` | iOS icon, Android ≤7 legacy icon | 1024px, background filled, whale 60% width |
| `app_icon_foreground.png` | Android adaptive foreground + monochrome | 1024px transparent, whale 49% width (diagonal ≈ 66dp of 108dp) |

Because the foreground PNG already includes the 108dp safe-zone padding, `adaptive_icon_foreground_inset: 0` disables the package's default 16% inset.

## Dependency pins

`flutter_inappwebview` is pinned to `6.2.0-beta.3`: the 6.1.5 stable Android implementation uses `proguard-android.txt`, which AGP 9 (used by this template) rejects. Overriding only `flutter_inappwebview_android` breaks the Windows implementation via the shared platform interface, so the whole family is on the beta. Move to `^6.2.0` once stable ships.

## Not done yet

Release signing / iOS provisioning, prod URL default, push notifications, camera/file upload permissions, JS bridge. iOS builds and runs on the simulator here (Xcode 27.2, `flutter build ios --simulator`); it has not been run on a real iPhone.
