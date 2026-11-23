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
