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
BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter build ipa ...  # App Store builds: strips geolocator's Always-permission code (SPM reads this env var); without it upload may warn ITMS-90683 (missing NSLocationAlwaysAndWhenInUseUsageDescription)
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

Everything lives in `lib/main.dart`, except the JS bridge in `lib/native_bridge.dart`, location measuring in `lib/location_reading.dart` and file downloads in `lib/file_download.dart`. The bridge is injected only into the `WEB_URL` origin's main frame (`javaScriptBridgeOriginAllowList` + `javaScriptBridgeForMainFrameOnly`): on Android the plugin computes the caller's origin and isMainFrame in page JS, so an iframe could spoof them; `NativeBridge.handle` re-checks as a second layer.

- `NativeBridge` (`lib/native_bridge.dart`) registers JS handlers in `onWebViewCreated`. Every call goes through `handle()`, which answers `{ok: false, error: 'forbidden'}` unless the call is from the main frame of an `isTrustedOrigin` page (https, same host and port as `WEB_URL`), and wraps results as `{ok: true, data}` or `{ok: false, error: 'failed'}` (exceptions are reported, never thrown to JS). Unknown handler names never reach Dart; the plugin returns `null`. The contract for the web side is `docs/native-bridge.md`; add new handlers there too. First handler: `appInfo` (`version`, `platform`).
- `measureLocation` (`lib/location_reading.dart`, bridge handler of the same name) runs the shared `LocationGate` permission check (same guide snackbars as the geolocation prompt), then takes the first fresh fix from `Geolocator.getPositionStream` (high accuracy, 8 s limit; never last-known, and fixes timestamped more than 2 s before the call are skipped because the OS may hand back a cached fix first: `firstFreshPosition`); with approximate-only access it takes the OS's first fix instead (`readAnyPosition`, Android refreshes coarse fixes rarely) and every ok result carries `ageSeconds` and returns coordinates, accuracy, `isMocked` and whether access is precise from that one reading (plan decision 8). The web waits 75 s for this call: the permission check is capped at 60 s overall (`permissionTimeout`), measuring at ~9 s, and the follow-up reads (accuracy, permission, service) at 2 s each, ~73 s worst case. On Android `callAsyncJavaScript` (used to wait for the first paint before hiding the splash) answers through the bridge, so it has a 2 s timeout now that the bridge is only in the `WEB_URL` main frame. Mock detection was verified on the emulator with a shell test provider (`appops set com.android.shell android:mock_location allow`, `cmd location providers add-test-provider gps`, `set-test-provider-location`).
- File downloads (plan decision 10, no web change): the payslip PDF (`/pay/<id>/pdf`, same-host attachment behind httpOnly cookies) arrives in `onDownloadStarting`; only when `isTrustedOrigin(url.origin)` does the app copy the webview cookies (`CookieManager.getCookies`) into its own `HttpClient` request. Redirects are followed by hand (`followRedirects = false`, at most `maxDownloadRedirects`) and the cookie is sent only while the hop is `isSameOrigin` with the first URL: the built-in redirect only drops cookies on a host change, so a same-host other-port or http hop would carry them. Redirect hops must be same-origin with the first URL or an S3 signed URL (`isSignedDownload`); anything else fails. Bodies are capped (`maxFileBytes` 50 MB, `maxMessageBytes` 64 KB) and by a total `downloadBodyTimeout` (60 s, the subscription is cancelled); the body is written chunk by chunk through a `RandomAccessFile`, pausing the response while each write runs, so slow storage never piles data up in memory and write errors fail the download besides the 15 s idle limit; a partial file is deleted. A signature query with an empty value is not a signed URL. When the app opens a download's HTML answer in the webview (`_openingInWebView`), that one navigation is not intercepted again even if it is the payslip PDF route (the mark expires after 5 s because Android does not call `shouldOverrideUrlLoading` for `loadUrl`). Main-frame navigations to the same-origin `/pay/<id>/pdf` route (`isPayslipPdf`) are cancelled in `shouldOverrideUrlLoading` and downloaded by the app, because its failure answers (plain-text 404/409/502, login redirect) are not downloads and the webview would open them as a page; this also stops the PDF being generated twice. Download errors are reported with URL queries stripped (`redactUrls`) so S3 signatures never reach the logs, and the share sheet gets a `sharePositionOrigin` (needed for the iPad popover). The contract file route 302s to an S3 signed URL; `shouldOverrideUrlLoading` cancels navigations where `isSignedDownload` (https, `*.amazonaws.com`, a signature query) and downloads without cookies. `downloadFile` saves under a fresh temp folder with the `Content-Disposition` name (api sends `filename*=UTF-8''…`) and the result opens in the `share_plus` share sheet; `text/plain` failures are shown as the message. A 200 HTML (e.g. login redirect) is opened in the webview at the final URL it came from, only for cookie (same-origin) downloads; if the same download comes back as HTML again within 15 s the app stops and asks the user to reopen the app (app and webview cookies disagree). Any other HTML (502 pages, S3) is a failure. Limits: connect through response headers 30 s, body 15 s idle, cookie read 5 s. iOS sends a main-frame error after the plugin cancels a PDF response, so main-frame errors for the intercepted URL within 3 s are ignored (other pages' errors still show the error screen). `isSignedDownload` only accepts S3 hosts (`s3.amazonaws.com`, `*.s3[.-]<region>.amazonaws.com`), not other AWS services. Responses whose body is not needed (200 HTML, non-200) return on headers without reading the body. `download-*` folders older than 10 min (`keepDownloadsFor`) in the shared temp dir are removed before each download; newer ones are kept because the share sheet may still be reading them (the download lock is released before sharing). The cookie is looked up again for every same-origin redirect hop (`cookieFor`) so cookie `Path` scoping matches the webview. Download tests use a real local `HttpServer`, so they live in `test/file_download_test.dart`: in a file with `testWidgets` the test binding turns every HTTP request into a 400.
- `isInApp(uri, base)` is the navigation rule: same host as `WEB_URL` over http(s), or webview-internal schemes (`about`, `data`, `blob`, `javascript`), stay in the webview. Everything else (other hosts, `tel:`, `mailto:`) is cancelled in `shouldOverrideUrlLoading` and opened with `url_launcher` externally. It, `isTrustedOrigin` (now in `native_bridge.dart`), `ensureLocationAccess`, `LocationGate`, `LocationAccess.allowsWeb`, `locationGuide`, `allowGeolocation`, `appUserAgent` and `readAppVersion` are the unit-tested functions (`test/widget_test.dart`); the webview itself is not testable in widget tests.
- Location: Android declares `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION`; iOS has `NSLocationWhenInUseUsageDescription`. When the page calls `navigator.geolocation`, Android routes it to `onGeolocationPermissionsShowPrompt`, which allows only `isTrustedOrigin` (https, same host as `WEB_URL`) and asks the OS permission via `geolocator` (`allowGeolocation` -> `ensureLocationAccess`), with `retain: false` (the webview does not store the grant, so each page load re-checks). `ensureLocationAccess` returns a `LocationAccess`: `precise`, `approximate` (Android 12+ "approximate" grant), `serviceDisabled` (device location off), `denied`, `deniedForever`, `failed` (error or timeout while checking/requesting). The web is allowed for the first three. If an approximate grant already existed, it re-requests once per app run so Android offers the upgrade-to-precise dialog, but not right after the user just picked approximate in the same flow; a failed re-request stays `approximate`. Each platform call has its own 60 s limit because geolocator on Android never completes if the permission dialog is interrupted (empty result); the limit also counts time the user spends deciding (known limitation). After the permission is granted, a failure to read service status or accuracy is treated as on/precise. `LocationGate` serialises requests: concurrent ones share one in-flight future (overlapping geolocator requests lose results), only the starter shows guidance, and `askPrecise` stays off after the first re-request. For `approximate`, `deniedForever`, `serviceDisabled` and `failed` a SnackBar (`locationGuide`) explains and, except for `failed`, offers app or location settings; if they cannot be opened a fallback text says where to go. Guidance that arrives while the splash is up (`_loaded` false) is held and shown in `_markLoaded`. The SnackBar sets `persist` to `MediaQuery.accessibleNavigationOf(context)`: an action would otherwise keep it on screen over the web's bottom Dock, but screen-reader users need time to reach the button. iOS has no equivalent hook in flutter_inappwebview: WKWebView asks the OS (and shows its own per-site prompt) itself, so `isTrustedOrigin` is **not** enforced on iOS. Per plan decision 8 the in-app check-in will later get coordinates from a native JS handler instead; this path is the fallback.
- `WebScreen` wraps the `InAppWebView`: `PopScope` maps Android back to webview history, then `SystemNavigator.pop()`. A main-frame load error (except `CANCELLED`) shows `_ErrorView`. User-Agent gets `WhaleStaffApp/<version>` appended (`appUserAgent`, version from `package_info_plus` read in `main()` before `runApp` via `readAppVersion`, which falls back to `unknown` on error, an empty version, or a 2 s timeout because `main()` holds the first frame while it waits) so the web app can detect the shell. It is for detection only, never for authorization.

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

Release signing / iOS provisioning, prod URL default, push notifications, camera/file upload permissions, the web side of `measureLocation` (web PR #87 then check-in screen). iOS builds and runs on the simulator here (Xcode 27.2, `flutter build ios --simulator`); it has not been run on a real iPhone.
