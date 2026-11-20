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

/// OS 위치 권한(앱 사용 중)을 확인하고, 허락되지 않았지만 다시 물을 수 있으면(denied) 묻는다.
/// 허락이면 true. 거부 · 영구 거부 · 오류 · [timeout] 초과면 false 이고, 웹은 위치 「거부」로 받는다.
/// Android 는 영구 거부여도 checkPermission 이 denied 를 돌려줘서 requestPermission 까지 가지만,
/// OS 가 창 없이 바로 거부한다.
/// geolocator(Android)는 권한 창이 중단되면(빈 결과) 결과를 돌려주지 않아 future 가 끝나지 않는다.
/// 그러면 웹의 위치 요청도 끝나지 않으므로 [timeout] 으로 끊는다.
Future<bool> ensureLocationPermission({
  Future<LocationPermission> Function() check = Geolocator.checkPermission,
  Future<LocationPermission> Function() request = Geolocator.requestPermission,
  Duration timeout = const Duration(seconds: 60),
}) async {
  try {
    Future<bool> run() async {
      var permission = await check();
      if (permission == LocationPermission.denied) {
        permission = await request();
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    }

    return await run().timeout(timeout);
  } catch (e, s) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'main',
        context: ErrorDescription('위치 권한을 확인하지 못해 웹의 위치 요청을 거부함'),
      ),
    );
    return false;
  }
}

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
  Future<bool>? _locationPermission;

  Future<bool> _ensureLocationPermission() => _locationPermission ??=
      ensureLocationPermission().whenComplete(() => _locationPermission = null);

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
