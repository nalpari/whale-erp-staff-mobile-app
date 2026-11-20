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

/// 웹이 위치를 물어도 되는 출처인지. 웹 주소와 같은 호스트의 https 만 허락한다.
bool isTrustedOrigin(String origin, Uri base) {
  final uri = Uri.tryParse(origin);
  return uri != null && uri.scheme == 'https' && uri.host == base.host;
}

/// 위치를 쓸 수 있는 상태. 웹의 위치 요청을 허락할지와 사용자에게 띄울 안내를 정한다.
enum LocationAccess {
  /// 정확한 위치까지 허락.
  precise,

  /// 「대략적 위치」만 허락(Android 12+). 좌표가 km 단위로 흐려져 근무지 판정이 틀릴 수 있다.
  approximate,

  /// 권한은 허락인데 기기 위치(위치 서비스)가 꺼져 있다. 웹은 좌표를 받지 못한다.
  serviceDisabled,

  /// 거부(다시 물을 수 있음) · 판단 불가 · 오류 · 시간 초과.
  denied,

  /// 영구 거부. OS 가 더는 창을 띄우지 않아 설정에서만 바꿀 수 있다.
  deniedForever;

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
/// 그러면 웹의 위치 요청도 끝나지 않으므로 단계마다 [timeout] 으로 끊는다. 첫 확인의 오류 · 시간 초과는
/// denied, 정확한 위치 재요청의 오류 · 시간 초과는 이미 가진 approximate 로 둔다. 둘 다 오류를 보고한다.
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
  Future<LocationAccess> guarded(
    Future<LocationAccess> Function() step,
    LocationAccess fallback,
    String context,
  ) async {
    try {
      return await step().timeout(timeout);
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

  Future<LocationAccess> byAccuracy() async =>
      await accuracy() == LocationAccuracyStatus.precise
      ? LocationAccess.precise
      : LocationAccess.approximate;

  var justAsked = false;
  final first = await guarded(
    () async {
      var permission = await check();
      if (permission == LocationPermission.denied) {
        justAsked = true;
        permission = await request();
      }
      if (permission == LocationPermission.deniedForever) {
        return LocationAccess.deniedForever;
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return LocationAccess.denied;
      }
      if (!await serviceEnabled()) return LocationAccess.serviceDisabled;
      return byAccuracy();
    },
    LocationAccess.denied,
    '위치 권한을 확인하지 못해 웹의 위치 요청을 거부함',
  );

  if (first != LocationAccess.approximate || !askPrecise || justAsked) {
    return first;
  }
  onAskPrecise?.call();
  return guarded(
    () async {
      await request();
      return byAccuracy();
    },
    LocationAccess.approximate,
    '정확한 위치를 다시 요청하지 못해 대략적 위치로 둠',
  );
}

/// 위치 상태에 맞춰 사용자에게 띄울 안내. 안내할 것이 없으면 null.
/// [appSettings] 가 true 면 앱 설정, false 면 기기 위치 설정을 연다.
({String message, String action, bool appSettings})? locationGuide(
  LocationAccess access,
) => switch (access) {
  LocationAccess.approximate => (
    message: '정확한 위치가 꺼져 있어 출퇴근 위치가 맞지 않을 수 있어요.',
    action: '설정',
    appSettings: true,
  ),
  LocationAccess.deniedForever => (
    message: '위치 권한이 꺼져 있어요. 출퇴근하려면 설정에서 위치를 허용해 주세요.',
    action: '설정',
    appSettings: true,
  ),
  LocationAccess.serviceDisabled => (
    message: '휴대폰 위치가 꺼져 있어요. 출퇴근하려면 위치를 켜 주세요.',
    action: '위치 켜기',
    appSettings: false,
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
  // 권한 창이 떠 있는 동안 온 요청은 같은 결과를 기다린다. 겹쳐 부르면 geolocator 가 앞 요청의 결과를 잃는다.
  Future<LocationAccess>? _locationAccess;
  // 「대략적 위치」면 정확한 위치로 바꿀지 앱을 켠 동안 한 번만 다시 묻는다. 페이지마다 물으면 귀찮다.
  bool _askedPrecise = false;

  Future<bool> _ensureLocationPermission() async {
    final existing = _locationAccess;
    if (existing != null) return (await existing).allowsWeb;
    // 이 요청이 확인을 시작한 쪽이다. 같이 기다린 요청은 안내를 다시 띄우지 않는다.
    final pending = _locationAccess = ensureLocationAccess(
      askPrecise: !_askedPrecise,
      onAskPrecise: () => _askedPrecise = true,
    ).whenComplete(() => _locationAccess = null);
    final access = await pending;
    if (mounted) _showLocationGuide(access);
    return access.allowsWeb;
  }

  void _showLocationGuide(LocationAccess access) {
    final guide = locationGuide(access);
    // 첫 페이지가 그려지기 전이면 스플래시 위에 뜨므로 띄우지 않는다.
    if (guide == null || !_loaded) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(guide.message),
          duration: const Duration(seconds: 6),
          // action 이 있으면 SnackBar 는 기본으로 사라지지 않고 하단 Dock 을 가린다. 시간이 지나면 닫는다.
          persist: false,
          showCloseIcon: true,
          action: SnackBarAction(
            label: guide.action,
            onPressed: guide.appSettings
                ? Geolocator.openAppSettings
                : Geolocator.openLocationSettings,
          ),
        ),
      );
  }

  void _markLoaded() {
    if (!_loaded) setState(() => _loaded = true);
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
