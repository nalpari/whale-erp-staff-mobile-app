import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'file_download.dart';
import 'location_reading.dart';
import 'native_bridge.dart';

// TODO: 운영 주소는 https://staff.whaleerp.co.kr 이다. 도메인이 열리면(2026-11-19 현재 DNS 미등록) 기본값을 운영으로 바꾼다.
// 그 전까지 기본값은 dev 이고, 다른 주소는 --dart-define=WEB_URL=... 로 넘긴다.
const webUrl = String.fromEnvironment(
  'WEB_URL',
  defaultValue: 'https://staff-dev.whaleerp.co.kr',
);

const primary = Color(0xFF4C4DDC);

// pubspec.yaml 의 flutter_native_splash 와 같은 값. 바꾸면 양쪽을 같이 바꾼다.
const splashColor = primary;
const splashLogo = AssetImage('assets/splash_logo.png');
// flutter_native_splash 는 이미지를 4x 로 본다. 720px 이미지 → 180dp.
const splashLogoSize = 180.0;

/// 앱 안에서 열 주소인지. 웹 주소와 같은 호스트의 http(s) 와 웹뷰 내부 스킴만 앱에서 연다.
bool isInApp(Uri uri, Uri base) {
  if (const ['about', 'data', 'blob', 'javascript'].contains(uri.scheme)) {
    return true;
  }
  return (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host == base.host;
}

/// OS 위치 권한(앱 사용 중)을 확인하고, 허락되지 않았지만 다시 물을 수 있으면(denied) 묻는다.
/// 이미 「대략적 위치」로 허락돼 있으면 [askPrecise] 일 때 한 번 더 물어 정확한 위치로 바꿀 기회를 준다
/// (Android 는 FINE 을 다시 요청하면 「정확한 위치로 변경」 창을 띄운다). 사용자가 이번 창에서 방금
/// 대략적 위치를 골랐으면 바로 다시 묻지 않는다. 다시 물을 때 [onAskPrecise] 를 부른다.
/// Android 는 영구 거부여도 checkPermission 이 denied 를 돌려줘서 requestPermission 까지 가지만,
/// OS 가 창 없이 바로 거부하고 deniedForever 가 돌아온다.
/// geolocator(Android)는 권한 창이 중단되면(빈 결과) 결과를 돌려주지 않아 future 가 끝나지 않는다.
/// 그러면 웹의 위치 요청도 끝나지 않으므로 플랫폼 호출마다 [timeout] 으로 끊고 오류를 보고한다.
/// - 권한 확인 · 요청이 실패하면 failed(웹 거부, 다시 시도 안내).
/// - 권한이 있는데 위치 서비스 · 정확도를 읽지 못하면 켜져 있고 정확한 것으로 보고 웹을 허락한다.
/// - 정확한 위치 재요청이 실패하면 이미 가진 approximate 로 둔다.
/// 시간 제한에는 사용자가 권한 창을 보고 고민하는 시간도 들어간다(알려진 한계).
Future<LocationAccess> ensureLocationAccess({
  Future<LocationPermission> Function() check = Geolocator.checkPermission,
  Future<LocationPermission> Function() request = Geolocator.requestPermission,
  Future<LocationAccuracyStatus> Function() accuracy =
      Geolocator.getLocationAccuracy,
  Future<bool> Function() serviceEnabled = Geolocator.isLocationServiceEnabled,
  bool askPrecise = true,
  VoidCallback? onAskPrecise,
  Duration timeout = const Duration(seconds: 60),
  Duration askWithin = permissionAskWindow,
  DateTime Function() now = DateTime.now,
  bool? onIOS,
}) async {
  final isIOS = onIOS ?? defaultTargetPlatform == TargetPlatform.iOS;
  // 권한 창(처음 요청 · 정확한 위치 재요청)은 확인을 시작하고 [askWithin] 안에서만 새로 띄운다. 그 뒤에는 부르는 쪽
  // (measureLocation 의 permissionTimeLimit)이 이미 시간 초과로 답했을 수 있어, 늦게 뜬 창이 웹 결과와 어긋난다.
  final startedAt = now();
  bool mayAsk() => now().difference(startedAt) < askWithin;
  Future<T> guarded<T>(
    Future<T> Function() call,
    T fallback,
    String context,
  ) async {
    try {
      return await call().timeout(timeout);
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'main',
          context: ErrorDescription(context),
        ),
      );
      return fallback;
    }
  }

  /// 허락이 아니면 그 상태, 허락이면 null.
  LocationAccess? blocked(LocationPermission? permission) =>
      switch (permission) {
        null => LocationAccess.failed,
        LocationPermission.whileInUse || LocationPermission.always => null,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };

  Future<LocationAccess> byAccuracy() async =>
      await guarded(
            accuracy,
            LocationAccuracyStatus.precise,
            '위치 정확도를 읽지 못해 정확한 위치로 봄',
          ) ==
          LocationAccuracyStatus.precise
      ? LocationAccess.precise
      : LocationAccess.approximate;

  // 확인과 요청에 시간 제한을 따로 건다. 하나로 묶으면 확인이 시간을 넘긴 뒤 늦게 denied 로 끝날 때
  // (timeout 은 원래 작업을 취소하지 않는다) 웹에 이미 거부를 돌려준 뒤에 OS 권한 창이 뜬다.
  final current = await guarded<LocationPermission?>(
    check,
    null,
    '위치 권한을 확인하지 못해 웹의 위치 요청을 거부함',
  );
  if (current == LocationPermission.denied && !mayAsk()) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: TimeoutException('권한 확인이 늦게 끝나 권한 창을 띄우지 않음', askWithin),
        library: 'main',
      ),
    );
    return LocationAccess.failed;
  }
  final justAsked = current == LocationPermission.denied;
  final permission = justAsked
      ? await guarded<LocationPermission?>(
          request,
          null,
          '위치 권한을 요청하지 못해 웹의 위치 요청을 거부함',
        )
      : current;
  final notGranted = blocked(permission);
  if (notGranted == LocationAccess.deniedForever &&
      isIOS &&
      !await guarded(serviceEnabled, true, '위치 서비스 상태를 읽지 못해 켜진 것으로 봄')) {
    // iOS 는 기기 위치를 전부 끄면 권한이 denied(→ deniedForever)로 보인다. 그때는 위치를 켜라고 안내한다.
    return LocationAccess.serviceDisabled;
  }
  if (notGranted != null) return notGranted;

  if (!await guarded(serviceEnabled, true, '위치 서비스 상태를 읽지 못해 켜진 것으로 봄')) {
    return LocationAccess.serviceDisabled;
  }
  final first = await byAccuracy();
  if (first != LocationAccess.approximate || !askPrecise || justAsked) {
    return first;
  }
  // 앞 단계가 늦어져 창을 띄울 시간이 지났으면 묻지 않고 대략적 위치로 둔다(다음 요청 때 다시 묻는다).
  if (!mayAsk()) return first;

  onAskPrecise?.call();
  final again = await guarded<LocationPermission?>(
    request,
    null,
    '정확한 위치를 다시 요청하지 못해 대략적 위치로 둠',
  );
  if (again == null) return LocationAccess.approximate;
  return blocked(again) ?? await byAccuracy();
}

/// 웹뷰 위치 요청을 한 줄로 세운다. 권한 창이 떠 있는 동안 온 요청은 같은 결과를 기다린다
/// (겹쳐 부르면 geolocator 가 앞 요청의 결과를 잃는다). 「대략적 위치」면 정확한 위치로 바꿀지
/// 앱을 켠 동안 한 번만 다시 묻는다. 페이지마다 물으면 귀찮다.
class LocationGate {
  LocationGate(this._ensure);

  final Future<LocationAccess> Function({
    required bool askPrecise,
    VoidCallback? onAskPrecise,
  })
  _ensure;
  Future<LocationAccess>? _pending;
  bool _askedPrecise = false;

  /// 위치 상태와, 이 호출이 확인을 시작했는지. 안내는 시작한 쪽만 띄운다.
  Future<({LocationAccess access, bool started})> request() async {
    final existing = _pending;
    if (existing != null) return (access: await existing, started: false);
    final pending = _pending = _ensure(
      askPrecise: !_askedPrecise,
      onAskPrecise: () => _askedPrecise = true,
    ).whenComplete(() => _pending = null);
    return (access: await pending, started: true);
  }
}

/// 사용자에게 띄울 위치 안내. 안내할 것이 없으면 null.
/// [action] 이 있으면 누를 때 [appSettings] 가 true 면 앱 설정, false 면 기기 위치 설정을 연다.
/// 설정을 열지 못하면 [fallback] 을 띄운다.
typedef LocationGuide = ({
  String message,
  String? action,
  bool appSettings,
  String fallback,
});

const _appSettingsFallback =
    '설정을 열지 못했어요. 휴대폰 설정 > 애플리케이션 > 웨일ERP 직원 > 권한에서 위치를 허용해 주세요.';

LocationGuide? locationGuide(LocationAccess access) => switch (access) {
  LocationAccess.approximate => (
    message: '정확한 위치가 꺼져 있어 출퇴근 위치가 맞지 않을 수 있어요.',
    action: '설정',
    appSettings: true,
    fallback: _appSettingsFallback,
  ),
  LocationAccess.deniedForever => (
    message: '위치 권한이 꺼져 있어요. 출퇴근하려면 설정에서 위치를 허용해 주세요.',
    action: '설정',
    appSettings: true,
    fallback: _appSettingsFallback,
  ),
  LocationAccess.serviceDisabled => (
    message: '휴대폰 위치가 꺼져 있어요. 출퇴근하려면 위치를 켜 주세요.',
    action: '위치 켜기',
    appSettings: false,
    fallback: '위치 설정을 열지 못했어요. 휴대폰 빠른 설정에서 위치를 켜 주세요.',
  ),
  LocationAccess.failed => (
    message: '위치 권한을 확인하지 못했어요. 잠시 뒤 다시 시도해 주세요.',
    action: null,
    appSettings: false,
    fallback: '',
  ),
  LocationAccess.precise || LocationAccess.denied => null,
};

/// 웹의 위치 요청을 허락할지. 믿는 출처가 아니면 OS 권한 창을 띄우지 않고 거부한다.
Future<bool> allowGeolocation(
  String origin,
  Uri base,
  Future<bool> Function() ensurePermission,
) async => isTrustedOrigin(origin, base) && await ensurePermission();

/// 웹이 앱 안에서 열렸는지 알아보는 User-Agent 접미사. 예: `WhaleStaffApp/1.0.0`.
String appUserAgent(String version) => 'WhaleStaffApp/$version';

/// 앱 버전을 읽는다. 실패하거나, 2초 안에 끝나지 않거나, 비어 있으면 `unknown`.
/// main() 은 첫 프레임을 미룬 채 이 값을 기다리므로, 여기서 예외가 새거나 멈추면 앱이 OS 스플래시에서 멈춘다.
Future<String> readAppVersion(Future<PackageInfo> Function() read) async {
  try {
    final version = (await read().timeout(const Duration(seconds: 2))).version;
    return version.isEmpty ? 'unknown' : version;
  } catch (e, s) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'main',
        context: ErrorDescription('앱 버전을 읽지 못해 User-Agent 에 unknown 을 붙임'),
      ),
    );
    return 'unknown';
  }
}

Future<void> main() async {
  // 고래 이미지 디코딩과 앱 버전 읽기가 끝날 때까지 첫 프레임을 미룬다. OS 스플래시가 걷힐 때 고래가 한 프레임 비지 않게.
  WidgetsFlutterBinding.ensureInitialized().deferFirstFrame();
  final version = await readAppVersion(PackageInfo.fromPlatform);
  runApp(
    MaterialApp(
      title: '웨일ERP 직원',
      debugShowCheckedModeBanner: false,
      home: WebScreen(version: version),
    ),
  );
}

class WebScreen extends StatefulWidget {
  const WebScreen({super.key, required this.version});

  /// 앱 버전. User-Agent 접미사와 브리지 `appInfo` 에 쓴다.
  final String version;

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  final _base = Uri.parse(webUrl);
  InAppWebViewController? _controller;
  late final _bridge = NativeBridge(
    base: _base,
    handlers: {
      'appInfo': appInfoHandler(
        version: widget.version,
        platform: defaultTargetPlatform,
      ),
      'measureLocation': (_) => measureLocation(
        ensureAccess: _ensureLocationAccess,
        currentPosition: readCurrentPosition,
        approximatePosition: readAnyPosition,
      ),
    },
  );
  late final _refresh = PullToRefreshController(
    settings: PullToRefreshSettings(color: primary),
    onRefresh: () => _controller?.reload(),
  );
  bool _failed = false;
  bool _loaded = false;
  bool _splashGone = false;
  // 파일을 받는 중이면 또 누른 것은 무시한다(같은 파일을 두 번 받아 공유 시트가 겹치지 않게).
  bool _downloading = false;
  // 웹뷰의 이동 · 받기를 앱이 가로챈 때. 바로 뒤 오는 main frame 오류는 가로채기 때문이라 오류 화면을 띄우지 않는다.
  DateTime? _interceptedAt;
  // 직전에 로그인 화면 등으로 웹뷰에 넘긴 받기. 같은 받기가 곧바로 또 화면을 받으면(앱이 읽은 쿠키가 웹뷰와 어긋남)
  // 로그인 → 받기 → 로그인이 사람 손 없이 되풀이되므로 끊는다.
  ({Uri url, DateTime at})? _lastOpenInWebView;

  bool _justIntercepted() {
    final at = _interceptedAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 3);
  }

  // 시간 제한이 지난 뒤 온 요청은 권한을 새로 요청한다. 앞 요청을 기다리게 하면 안 된다:
  // geolocator(Android)는 권한 창이 취소되면(빈 결과) 앞 요청을 영영 끝내지 않아 앱을 다시 켤 때까지
  // 위치를 못 쓴다. 새 요청은 앞 요청의 결과 콜백을 덮어쓰므로, 창이 아직 떠 있었다면 그 창의 결과는
  // 새 요청이 받는다(앞 요청은 이미 시간 초과로 웹에 답했다).
  final _locationGate = LocationGate(
    ({required askPrecise, onAskPrecise}) => ensureLocationAccess(
      askPrecise: askPrecise,
      onAskPrecise: onAskPrecise,
    ),
  );
  // 지금 떠 있는 위치 안내. 닫히면 null.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _guideBar;
  // 스플래시가 떠 있는 동안 나온 안내. 첫 페이지가 그려지면 띄운다.
  LocationGuide? _pendingGuide;

  /// 위치 권한을 확인하고(필요하면 묻고) 안내를 띄운다. 웹 geolocation 요청과 브리지 `measureLocation` 이 같이 쓴다.
  Future<LocationAccess> _ensureLocationAccess() async {
    final result = await _locationGate.request();
    if (result.started && mounted) {
      final guide = locationGuide(result.access);
      if (_loaded) {
        if (guide != null) {
          _showLocationGuide(guide);
        } else if (_guideBar != null) {
          // 다시 확인해 괜찮아졌으면 떠 있는 위치 안내만 닫는다(화면 읽기 사용 시에는 저절로 안 닫힌다).
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
      } else {
        // 첫 페이지 전에는 최신 결과로 덮는다. 앞 확인이 실패했어도 다시 확인해 괜찮아졌으면(null) 지난 안내를 버린다.
        _pendingGuide = guide;
      }
    }
    return result.access;
  }

  Future<bool> _ensureLocationPermission() async =>
      (await _ensureLocationAccess()).allowsWeb;

  /// 웹뷰 대신 앱이 파일을 받아 공유 시트로 연다. [withCookies] 면 웹뷰 쿠키(로그인)를 싣는다(같은 호스트의 급여 PDF).
  Future<void> _receiveFile(
    Uri url, {
    required bool withCookies,
    required String fallbackName,
  }) async {
    // 웹뷰가 받으려던 이동을 가로챘다. iOS 는 PDF 응답을 cancel 하면 main frame 오류(WebKitErrorDomain 102 등)를
    // 보내므로, 바로 뒤 오는 오류는 연결 실패 화면으로 보지 않는다(onReceivedError).
    _interceptedAt = DateTime.now();
    if (_downloading) return;
    _downloading = true;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('파일을 받는 중이에요…'), duration: downloadTimeout),
    );
    void fail(
      Object error,
      StackTrace? stack, {
      String context = '파일을 받지 못함',
      String message = downloadFailedMessage,
    }) {
      // 예외 글에 S3 서명 주소가 들어 있을 수 있어 쿼리를 지우고 남긴다.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError(
            '${error.runtimeType}: ${redactUrls(error.toString())}',
          ),
          stack: stack,
          library: 'main',
          context: ErrorDescription(context),
        ),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(message), showCloseIcon: true),
      );
    }

    try {
      String? cookie;
      if (withCookies) {
        // 쿠키 저장소가 답하지 않으면 받기가 끝나지 않고 중복 탭 막기도 풀리지 않으므로 제한을 건다.
        final cookies = await CookieManager.instance()
            .getCookies(url: WebUri.uri(url))
            .timeout(const Duration(seconds: 5));
        cookie = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
      final outcome = await downloadFile(
        url,
        directory: await getTemporaryDirectory(),
        fallbackName: fallbackName,
        cookie: cookie,
        userAgent: appUserAgent(widget.version),
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      switch (outcome) {
        case DownloadedFile(:final path, :final mimeType):
          // 공유 시트는 모달이라 중복 탭이 들어오지 않는다. 시트가 닫히지 않아도 다음 받기가 막히지 않게 먼저 푼다.
          _downloading = false;
          try {
            await SharePlus.instance.share(
              ShareParams(
                files: [XFile(path, mimeType: mimeType)],
                // iPad 에서는 공유 창(팝오버)을 띄울 기준 위치가 있어야 한다. 화면 가운데를 준다.
                sharePositionOrigin: Rect.fromCenter(
                  center: MediaQuery.sizeOf(context).center(Offset.zero),
                  width: 1,
                  height: 1,
                ),
              ),
            );
          } catch (e, s) {
            fail(
              e,
              s,
              context: '받은 파일의 공유 화면을 열지 못함',
              message: '파일은 받았지만 공유 화면을 열지 못했어요. 잠시 뒤 다시 시도해 주세요.',
            );
          }
        case DownloadMessage(:final message):
          messenger.showSnackBar(
            SnackBar(content: Text(message), showCloseIcon: true),
          );
        case OpenInWebView(url: final page):
          // 접속이 끝나 로그인 화면이 온 경우 등. HTML 이 온 최종 주소(로그인 · 상세)를 연다. 웹이 로그인 뒤 돌려보낸다.
          // 쿠키를 싣는 같은 출처 받기에서만 이렇게 한다. S3 등 다른 곳의 HTML 은 받기 실패로 본다
          // (그 주소를 다시 열면 같은 가로채기로 되풀이된다).
          final last = _lastOpenInWebView;
          final repeated =
              last != null &&
              last.url == url &&
              DateTime.now().difference(last.at) < const Duration(seconds: 15);
          if (repeated) {
            _lastOpenInWebView = null;
            fail(
              StateError('받기가 화면으로 되풀이됨: $page'),
              null,
              message: '로그인 정보를 확인하지 못했어요. 앱을 다시 열고 시도해 주세요.',
            );
          } else if (withCookies && isTrustedOrigin(page.origin, _base)) {
            _lastOpenInWebView = (url: url, at: DateTime.now());
            // 웹뷰가 이 화면을 여는 데 생긴 오류는 연결 실패 화면으로 보여야 하므로 가로채기 창을 닫는다.
            _interceptedAt = null;
            await _controller?.loadUrl(
              urlRequest: URLRequest(url: WebUri.uri(page)),
            );
          } else {
            fail(StateError('파일 대신 화면이 옴: $page'), null);
          }
        case DownloadFailed(:final error, :final stack):
          fail(error, stack);
      }
    } catch (e, s) {
      if (mounted) messenger.hideCurrentSnackBar();
      fail(e, s);
    } finally {
      _downloading = false;
    }
  }

  void _showLocationGuide(LocationGuide guide) {
    final messenger = ScaffoldMessenger.of(context);
    final action = guide.action;
    messenger.removeCurrentSnackBar();
    final bar = _guideBar = messenger.showSnackBar(
      SnackBar(
        content: Text(guide.message),
        duration: const Duration(seconds: 6),
        // action 이 있으면 SnackBar 는 기본으로 사라지지 않고 하단 Dock 을 가린다. 시간이 지나면 닫되,
        // 화면 읽기 프로그램을 쓰면 버튼까지 갈 시간이 필요하니 남겨 둔다.
        persist: MediaQuery.accessibleNavigationOf(context),
        showCloseIcon: true,
        action: action == null
            ? null
            : SnackBarAction(
                label: action,
                onPressed: () async {
                  final opened = await (guide.appSettings
                      ? Geolocator.openAppSettings()
                      : Geolocator.openLocationSettings());
                  if (!opened && mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(guide.fallback),
                        duration: const Duration(seconds: 8),
                        showCloseIcon: true,
                      ),
                    );
                  }
                },
              ),
      ),
    );
    bar.closed.whenComplete(() {
      if (_guideBar == bar) _guideBar = null;
    });
  }

  void _markLoaded() {
    if (_loaded) return;
    setState(() => _loaded = true);
    final guide = _pendingGuide;
    _pendingGuide = null;
    if (guide != null) _showLocationGuide(guide);
  }

  Future<void> _back() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Stack(
            children: [
              SafeArea(
                child: Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(webUrl)),
                      initialSettings: InAppWebViewSettings(
                        applicationNameForUserAgent: appUserAgent(
                          widget.version,
                        ),
                        useShouldOverrideUrlLoading: true,
                        // Android 는 브리지 호출의 출처 · 맨 위 화면 여부를 페이지 안 JS 가 계산해 넘겨서 iframe 이 위조할 수
                        // 있다. 브리지 스크립트를 웹 주소의 맨 위 화면에만 심어, iframe 에서는 callHandler 자체가 없게 한다.
                        // NativeBridge.handle 의 출처 · 맨 위 화면 검사는 2차 방어로 남긴다.
                        javaScriptBridgeOriginAllowList: {_base.origin},
                        javaScriptBridgeForMainFrameOnly: true,
                      ),
                      pullToRefreshController: _refresh,
                      // 급여 PDF 「명세서 내보내기」(download 링크, attachment). 웹뷰는 파일을 받지 않으므로 앱이 웹뷰 쿠키를
                      // 실어 받는다. S3 서명 주소는 쿠키 없이 받는다. 그 밖의 다운로드는 무시한다.
                      onDownloadStarting: (controller, request) {
                        final url = request.url;
                        // 쿠키(로그인)를 싣는 곳은 웹 주소와 같은 출처(https · 호스트 · 포트)뿐이다. http 로는 보내지 않는다.
                        if ((url.scheme == 'https' || url.scheme == 'http') &&
                            isTrustedOrigin(url.origin, _base)) {
                          unawaited(
                            _receiveFile(
                              url,
                              withCookies: true,
                              fallbackName: '급여명세서.pdf',
                            ),
                          );
                        } else if (isSignedDownload(url)) {
                          unawaited(
                            _receiveFile(
                              url,
                              withCookies: false,
                              fallbackName: '근로계약서',
                            ),
                          );
                        }
                        return null;
                      },
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        _bridge.attach(controller);
                      },
                      // Android 전용: 웹이 navigator.geolocation 을 부르면 여기로 온다. 웹뷰는 자체 확인 창이 없어서
                      // OS 권한 창만 뜬다. 앱 안의 출퇴근 위치는 나중에 네이티브가 직접 잰다(계획 결정 8).
                      // 이 처리는 웹이 geolocation 을 부를 때를 대비한 것이다. retain 을 끄면 웹뷰가 출처별 허락을
                      // 저장하지 않아, 페이지를 새로 불러올 때마다 여기서 OS 권한을 다시 확인한다.
                      // iOS 에는 이 콜백이 없다. WKWebView 가 OS 권한(Info.plist 사유 문구)과 자체 사이트 확인 창을
                      // 직접 띄우고, 출처 검사(isTrustedOrigin)는 적용되지 않는다.
                      onGeolocationPermissionsShowPrompt:
                          (controller, origin) async {
                            final allow = await allowGeolocation(
                              origin,
                              _base,
                              _ensureLocationPermission,
                            );
                            return GeolocationPermissionShowPromptResponse(
                              origin: origin,
                              allow: allow,
                              retain: false,
                            );
                          },
                      shouldOverrideUrlLoading: (controller, action) async {
                        final uri = action.request.url;
                        // 급여 PDF 「명세서 내보내기」: 실패 응답(평문 오류 · 로그인 이동)은 웹뷰가 페이지로 열어 오류 글이
                        // 화면을 덮으므로, 웹뷰가 이동하기 전에 앱이 쿠키를 실어 받는다. 성공 PDF 도 한 번만 만들어진다.
                        if (uri != null &&
                            action.isForMainFrame &&
                            isPayslipPdf(uri, _base)) {
                          unawaited(
                            _receiveFile(
                              uri,
                              withCookies: true,
                              fallbackName: '급여명세서.pdf',
                            ),
                          );
                          return NavigationActionPolicy.CANCEL;
                        }
                        if (uri == null ||
                            !action.isForMainFrame ||
                            isInApp(uri, _base)) {
                          return NavigationActionPolicy.ALLOW;
                        }
                        // 근로계약서 받기: 같은 호스트 라우트가 S3 서명 주소로 302 이동한다. 바깥 브라우저로 내보내지 않고
                        // 앱이 받아 공유 시트로 연다. 서명 주소가 곧 권한이라 쿠키는 싣지 않는다.
                        if (isSignedDownload(uri)) {
                          unawaited(
                            _receiveFile(
                              uri,
                              withCookies: false,
                              fallbackName: '근로계약서',
                            ),
                          );
                          return NavigationActionPolicy.CANCEL;
                        }
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                        return NavigationActionPolicy.CANCEL;
                      },
                      onLoadStop: (controller, _) async {
                        _refresh.endRefreshing();
                        if (_loaded) return;
                        // onLoadStop 은 그리기 전에 온다. 바로 걷으면 빈 흰 웹뷰가 비친다.
                        // 웹이 한 프레임 그린 뒤(rAF 두 번)에 스플래시를 걷는다.
                        // Android 의 callAsyncJavaScript 는 브리지(callHandler)로 결과를 받는다. 브리지는 웹 주소의 맨 위 화면에만
                        // 심으므로, 다른 출처 페이지에서는 답이 오지 않을 수 있어 2초로 끊는다(스플래시가 영원히 남지 않게).
                        try {
                          await controller
                              .callAsyncJavaScript(
                                functionBody: 'await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));',
                              )
                              .timeout(const Duration(seconds: 2));
                        } on TimeoutException {
                          // 그려졌는지 확인하지 못했어도 스플래시는 걷는다.
                        } finally {
                          if (mounted) _markLoaded();
                        }
                      },
                      onReceivedError: (_, request, error) {
                        _refresh.endRefreshing();
                        if (request.isForMainFrame == false ||
                            error.type == WebResourceErrorType.CANCELLED ||
                            _justIntercepted()) {
                          return;
                        }
                        setState(() => _failed = true);
                        _markLoaded();
                      },
                    ),
                    if (_failed) _ErrorView(onRetry: _retry),
                  ],
                ),
              ),
              if (!_splashGone)
                SplashOverlay(
                  visible: !_loaded,
                  onHidden: () => setState(() => _splashGone = true),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// OS 스플래시가 걷힌 자리에 같은 고래를 멈춘 채 두었다가, 첫 페이지가 뜨면 페이드 아웃한다.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({
    super.key,
    required this.visible,
    required this.onHidden,
  });

  final bool visible;
  final VoidCallback onHidden;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> {
  bool _precaching = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_precaching) {
      _precaching = true;
      precacheImage(
        splashLogo,
        context,
      ).whenComplete(WidgetsBinding.instance.allowFirstFrame);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: const Duration(milliseconds: 300),
          onEnd: widget.onHidden,
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: ColoredBox(
              color: splashColor,
              child: const Center(
                child: Image(
                  image: splashLogo,
                  width: splashLogoSize,
                  height: splashLogoSize,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '연결할 수 없습니다',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('네트워크 상태를 확인한 뒤 다시 시도해 주세요.'),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: primary),
              onPressed: onRetry,
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}
