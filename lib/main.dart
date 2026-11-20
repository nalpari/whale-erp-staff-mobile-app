import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// 웹이 위치를 물어도 되는 출처인지. 웹 주소와 같은 출처(https · 호스트 · 포트)만 허락한다.
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

/// 위치를 쓸 수 있는 상태. 웹의 위치 요청을 허락할지와 사용자에게 띄울 안내를 정한다.
enum LocationAccess {
  /// 정확한 위치까지 허락.
  precise,

  /// 「대략적 위치」만 허락(Android 12+). 좌표가 km 단위로 흐려져 근무지 판정이 틀릴 수 있다.
  approximate,

  /// 권한은 허락인데 기기 위치(위치 서비스)가 꺼져 있다. 웹은 좌표를 받지 못한다.
  serviceDisabled,

  /// 거부(다시 물을 수 있음) · 판단 불가.
  denied,

  /// 영구 거부. OS 가 더는 창을 띄우지 않아 설정에서만 바꿀 수 있다.
  deniedForever,

  /// 권한을 확인하다 오류가 나거나 시간이 넘었다. 사용자가 거부한 것이 아니므로 다시 시도하라고 안내한다.
  failed;

  /// 웹뷰에 위치를 허락할지. 권한이 있으면 허락하고, 좌표 품질 문제는 안내로 알린다.
  bool get allowsWeb =>
      this == precise || this == approximate || this == serviceDisabled;
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
}) async {
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
  final justAsked = current == LocationPermission.denied;
  final permission = justAsked
      ? await guarded<LocationPermission?>(
          request,
          null,
          '위치 권한을 요청하지 못해 웹의 위치 요청을 거부함',
        )
      : current;
  final notGranted = blocked(permission);
  if (notGranted != null) return notGranted;

  if (!await guarded(serviceEnabled, true, '위치 서비스 상태를 읽지 못해 켜진 것으로 봄')) {
    return LocationAccess.serviceDisabled;
  }
  final first = await byAccuracy();
  if (first != LocationAccess.approximate || !askPrecise || justAsked) {
    return first;
  }

  onAskPrecise?.call();
  final again = await guarded<LocationPermission?>(
    request,
    null,
    '정확한 위치를 다시 요청하지 못해 대략적 위치로 둠',
  );
  if (again == null) return LocationAccess.approximate;
  return blocked(again) ?? await byAccuracy();
}

/// 같은 비동기 호출을 한 번에 하나만 돌린다. 돌고 있으면 새로 부르지 않고 그 결과를 같이 기다린다.
/// 위치 권한 창에 쓴다. 시간 제한([ensureLocationAccess] 의 timeout)은 웹에 돌려줄 답만 끊고 OS 권한 창은
/// 그대로 떠 있으므로, 그동안 온 요청이 requestPermission 을 다시 부르면 결과 콜백이 엉킨다.
class SingleFlight<T> {
  Future<T>? _running;

  Future<T> run(Future<T> Function() call) =>
      _running ??= call().whenComplete(() => _running = null);
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
      home: WebScreen(userAgent: appUserAgent(version)),
    ),
  );
}

class WebScreen extends StatefulWidget {
  const WebScreen({super.key, required this.userAgent});

  /// 기본 User-Agent 끝에 붙일 값.
  final String userAgent;

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  final _base = Uri.parse(webUrl);
  InAppWebViewController? _controller;
  late final _refresh = PullToRefreshController(
    settings: PullToRefreshSettings(color: primary),
    onRefresh: () => _controller?.reload(),
  );
  bool _failed = false;
  bool _loaded = false;
  bool _splashGone = false;
  // OS 권한 창은 시간 제한이 지나도 떠 있을 수 있어, 창이 닫히기 전에는 다시 띄우지 않는다.
  final _permissionRequest = SingleFlight<LocationPermission>();
  late final _locationGate = LocationGate(
    ({required askPrecise, onAskPrecise}) => ensureLocationAccess(
      askPrecise: askPrecise,
      onAskPrecise: onAskPrecise,
      request: () => _permissionRequest.run(Geolocator.requestPermission),
    ),
  );
  // 지금 떠 있는 위치 안내. 닫히면 null.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _guideBar;
  // 스플래시가 떠 있는 동안 나온 안내. 첫 페이지가 그려지면 띄운다.
  LocationGuide? _pendingGuide;

  Future<bool> _ensureLocationPermission() async {
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
    return result.access.allowsWeb;
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
                        applicationNameForUserAgent: widget.userAgent,
                        useShouldOverrideUrlLoading: true,
                      ),
                      pullToRefreshController: _refresh,
                      onWebViewCreated: (controller) =>
                          _controller = controller,
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
                        if (uri == null ||
                            !action.isForMainFrame ||
                            isInApp(uri, _base)) {
                          return NavigationActionPolicy.ALLOW;
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
                        try {
                          await controller.callAsyncJavaScript(
                            functionBody: 'await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));',
                          );
                        } finally {
                          if (mounted) _markLoaded();
                        }
                      },
                      onReceivedError: (_, request, error) {
                        _refresh.endRefreshing();
                        if (request.isForMainFrame == false ||
                            error.type == WebResourceErrorType.CANCELLED) {
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
