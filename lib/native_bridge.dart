import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 웹이 부를 수 있는 앱 기능 하나. 웹이 넘긴 인자를 받아 JSON 으로 바꿀 수 있는 값을 돌려준다.
typedef BridgeHandler = FutureOr<Object?> Function(List<dynamic> args);

/// 브리지 호출을 거절하거나 실패했을 때 웹에 돌려주는 오류 코드.
abstract final class BridgeError {
  /// 웹 주소와 다른 출처이거나 맨 위 화면(main frame)이 아닌 곳에서 불렀다.
  static const forbidden = 'forbidden';

  /// 앱 기능이 예외를 던졌다. 자세한 내용은 앱 로그에만 남긴다.
  static const failed = 'failed';
}

/// 웹(JS) ↔ 앱 통로. 웹은 `window.flutter_inappwebview.callHandler(이름, ...인자)` 로 부르고,
/// 앱은 언제나 `{ok: true, data: ...}` 또는 `{ok: false, error: <BridgeError>}` 하나로 답한다.
///
/// 계획서 조건: 웹 주소([base])와 같은 출처(https · 호스트 · 포트)의 맨 위 화면에서 온 호출만 받는다.
/// 1차로 웹뷰 설정(`javaScriptBridgeOriginAllowList` · `javaScriptBridgeForMainFrameOnly`)이 브리지를 웹 주소의
/// 맨 위 화면에만 심어, iframe 에는 `callHandler` 가 없다. 그래도 온 호출은 여기서 다시 검사해, 맞지 않으면
/// 앱 기능을 부르지 않고 `forbidden` 으로 답한다. 이 검사는 플러그인이 넘기는 출처 · 맨 위 화면 값을 믿는다.
/// User-Agent(`WhaleStaffApp/`)는 웹이 앱 안인지 알아보는 용도일 뿐, 여기서 권한 확인에 쓰지 않는다.
class NativeBridge {
  NativeBridge({required this.base, required this.handlers});

  /// 호출을 받아 줄 웹 주소.
  final Uri base;

  /// 이름별 앱 기능. 이름은 웹의 `callHandler` 첫 인자와 같다.
  final Map<String, BridgeHandler> handlers;

  /// 웹뷰에 기능을 등록한다. 웹 스크립트가 부르기 전에 등록돼야 하므로 `onWebViewCreated` 에서 부른다.
  void attach(InAppWebViewController controller) {
    for (final name in handlers.keys) {
      controller.addJavaScriptHandler(
        handlerName: name,
        callback: (JavaScriptHandlerFunctionData data) => handle(
          name,
          origin: data.origin.toString(),
          isMainFrame: data.isMainFrame,
          args: data.args,
        ),
      );
    }
  }

  /// 호출 하나를 검사하고 처리한다. 웹뷰 없이 테스트할 수 있게 [attach] 와 나눠 둔다.
  Future<Map<String, Object?>> handle(
    String name, {
    required String origin,
    required bool isMainFrame,
    List<dynamic> args = const [],
  }) async {
    final handler = handlers[name];
    if (handler == null || !isMainFrame || !isTrustedOrigin(origin, base)) {
      return {'ok': false, 'error': BridgeError.forbidden};
    }
    try {
      return {'ok': true, 'data': await handler(args)};
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'native_bridge',
          context: ErrorDescription('브리지 기능 $name 실패'),
        ),
      );
      return {'ok': false, 'error': BridgeError.failed};
    }
  }
}

/// 웹 주소와 같은 출처(https · 호스트 · 포트)인지. 위치 요청 허락과 브리지 호출에 같이 쓴다.
/// 같은 호스트라도 포트가 다르면 다른 서비스일 수 있어 거부한다. [Uri.port] 는 생략된 포트를 443 으로 본다.
bool isTrustedOrigin(String origin, Uri base) {
  final uri = Uri.tryParse(origin);
  return uri != null &&
      uri.scheme == 'https' &&
      base.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.host == base.host &&
      uri.port == base.port;
}

/// `appInfo`: 앱 버전과 운영체제. 웹이 브리지가 살아 있는지 확인하고, 버전별로 기능을 켜고 끌 때 쓴다.
BridgeHandler appInfoHandler({
  required String version,
  required TargetPlatform platform,
}) =>
    (_) => {
      'version': version,
      'platform': switch (platform) {
        TargetPlatform.iOS => 'ios',
        TargetPlatform.android => 'android',
        _ => 'other',
      },
    };

/// 앱 안쪽 기능 `pullToRefresh`. 웹 화면이 부르는 것이 아니라 앱이 심은 [pullToRefreshGuardScript] 가 부른다.
/// 인자 하나(참 · 거짓)로 당겨서 새로고침을 켜고 끈다. 인자가 참 · 거짓이 아니면 `failed`.
BridgeHandler pullToRefreshHandler(
  FutureOr<void> Function(bool enabled) setEnabled,
) => (args) async {
  final enabled = args.isEmpty ? null : args.first;
  if (enabled is! bool) {
    throw ArgumentError('pullToRefresh 인자는 참 · 거짓 하나: $args');
  }
  await setEnabled(enabled);
  return null;
};

/// 페이지가 열릴 때 심는 스크립트. 서명 패드처럼 `touch-action: none` 인 곳이 있으면 앱의 당겨서 새로고침을 끈다.
/// Android 는 웹뷰 맨 위에서 아래로 끌면 앱(SwipeRefreshLayout)이 먼저 가로채 페이지를 새로 고치므로, 위에서 아래로 긋는
/// 서명이 새로고침으로 날아갈 수 있다. 웹은 고치지 않는다.
/// - 서명 패드(`touch-none` · 인라인 `touch-action: none`)가 화면에 보이면 그동안 미리 끈다(present, 숨겨진 패드는 세지 않음). 누르는 순간에
///   끄면 비동기 브리지가 늦어 맨 위에서 빠르게 그은 첫 획을 새로고침이 먼저 가로챌 수 있다(PR #9 pr-agent 리뷰).
/// - 누른 곳과 그 부모 가운데 계산된 `touch-action` 이 `none` 인 것이 있으면 손을 뗄 때까지 끈다(off, 클래스를 못 찾는 경우 대비).
/// - 둘 다 아니면 켠다. 브리지가 아직 없으면 준비 이벤트 때 다시 맞춘다.
const pullToRefreshGuardScript = '''
(() => {
  if (window.__whalePullGuard) return;
  window.__whalePullGuard = true;
  let off = false;
  let present = false;
  let sent = null;
  const sync = (force) => {
    const enabled = !(off || present);
    if (!force && enabled === sent) return;
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      sent = enabled;
      bridge.callHandler('pullToRefresh', enabled).catch(() => {});
    }
  };
  const PAD = '.touch-none,[style*="touch-action: none"],[style*="touch-action:none"]';
  const scan = () => {
    // 숨겨진 패드(display: none, 닫힌 dialog 안 등)는 빼고 화면에 보이는 패드만 센다 — 숨긴 채 두면 새로고침이 다시 켜지지 않는다.
    const next = Array.from(document.querySelectorAll(PAD)).some((el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden');
    if (next !== present) {
      present = next;
      sync(false);
    }
  };
  let queued = false;
  const queueScan = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; scan(); });
  };
  new MutationObserver(queueScan).observe(document, {
    // 속성은 거르지 않는다 — 모달 열림 상태를 data-state 같은 임의 속성으로 바꾸고 CSS 로 패드를 숨기는 경우도 다시 검사한다(한 프레임에 한 번).
    childList: true, subtree: true, attributes: true,
  });
  document.addEventListener('DOMContentLoaded', scan);
  window.addEventListener('flutterInAppWebViewPlatformReady', () => sync(true));
  // 뒤로 가기 캐시(bfcache)에서 문서가 되살아나면 DOMContentLoaded 가 다시 오지 않고, 앱은 그 사이 onLoadStart 로 새로고침을
  // 켰다. 다시 검사하고 앱 상태를 맞춘다.
  window.addEventListener('pageshow', (event) => {
    if (!event.persisted) return;
    off = false;
    present = Array.from(document.querySelectorAll(PAD)).some((el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden');
    sync(true);
  });
  const blocksPull = (node) => {
    for (let el = node instanceof Element ? node : node && node.parentElement; el; el = el.parentElement) {
      if (getComputedStyle(el).touchAction === 'none') return true;
    }
    return false;
  };
  document.addEventListener('touchstart', (event) => {
    if (!off && blocksPull(event.target)) {
      off = true;
      sync(false);
    }
  }, { capture: true, passive: true });
  const release = (event) => {
    if (off && event.touches.length === 0) {
      off = false;
      sync(false);
    }
  };
  document.addEventListener('touchend', release, { capture: true, passive: true });
  document.addEventListener('touchcancel', release, { capture: true, passive: true });
})();
''';

/// 기기 식별자 형식 — 앱(MainActivity · AppDelegate)이 기기 고유값에 앞말을 붙여 SHA-256 으로 바꾼 64자 소문자 16진수.
final _deviceIdPattern = RegExp(r'^[0-9a-f]{64}$');

/// 브리지 기능 `deviceId` (계획 결정 9). 웹 로그인이 쿠키 UUID 대신 쓰는 기기 식별자. 기기 고유값(Android ANDROID_ID ·
/// iOS identifierForVendor)은 앱 밖으로 내보내지 않고 해시만 넘긴다. 2초 안에 못 읽거나 형식이 다르면 `failed`.
/// [nativeGuarded] 가 false 면 넘기지 않는다(`failed`). Android 는 웹뷰가 문서 시작 스크립트를 지원할 때만 브리지 스크립트를 웹 주소의
/// 맨 위 화면에 네이티브로 한정해 심는다. 지원하지 않는 오래된 웹뷰에서는 그 보장이 약하므로, 오래 남는 기기 식별자는 넘기지 않는다
/// (웹은 실패하면 쿠키 UUID 로 로그인한다).
BridgeHandler deviceIdHandler(
  Future<String?> Function() read, {
  Future<bool> Function()? nativeGuarded,
}) => (_) async {
  if (nativeGuarded != null && !await nativeGuarded()) {
    throw StateError('웹뷰가 브리지를 맨 위 화면에 네이티브로 한정하지 못해 기기 식별자를 넘기지 않음');
  }
  final id = await read().timeout(const Duration(seconds: 2));
  if (id == null || !_deviceIdPattern.hasMatch(id)) {
    throw StateError('기기 식별자를 읽지 못함');
  }
  return {'deviceId': id};
};
