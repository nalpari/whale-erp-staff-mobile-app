import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

// TODO: prod 주소가 정해지면 기본값을 prod 로 바꾼다. dev 는 --dart-define=WEB_URL=... 로 넘긴다.
const webUrl = String.fromEnvironment(
  'WEB_URL',
  defaultValue: 'https://staff-dev.whaleerp.co.kr',
);

const primary = Color(0xFF4C4DDC);

// pubspec.yaml 의 flutter_native_splash 와 같은 값. 바꾸면 양쪽을 같이 바꾼다.
const splashColor = Color(0xFF0A0A0A);
const splashLogo = AssetImage('assets/splash_logo.png');
// flutter_native_splash 는 이미지를 4x 로 본다. 720px 이미지 → 180dp.
const splashLogoSize = 180.0;
// 고래(대각선 약 180dp)를 둘러싸는 로딩 링.
const splashRingSize = 210.0;
const splashWhale = Color(0xFFF7FE57);

/// 앱 안에서 열 주소인지. 웹 주소와 같은 호스트의 http(s) 와 웹뷰 내부 스킴만 앱에서 연다.
bool isInApp(Uri uri, Uri base) {
  if (const ['about', 'data', 'blob', 'javascript'].contains(uri.scheme)) {
    return true;
  }
  return (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host == base.host;
}

void main() {
  // 고래 이미지를 디코딩할 때까지 첫 프레임을 미룬다. OS 스플래시가 걷힐 때 고래가 한 프레임 비지 않게.
  WidgetsFlutterBinding.ensureInitialized().deferFirstFrame();
  runApp(
    const MaterialApp(
      title: 'WHALEERP',
      debugShowCheckedModeBanner: false,
      home: WebScreen(),
    ),
  );
}

class WebScreen extends StatefulWidget {
  const WebScreen({super.key});

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
  bool _webViewAttached = false;

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
                        applicationNameForUserAgent: 'WhaleERPStaffApp',
                        useShouldOverrideUrlLoading: true,
                      ),
                      pullToRefreshController: _refresh,
                      onWebViewCreated: (controller) async {
                        _controller = controller;
                        // 웹뷰가 화면 합성에 붙는 프레임이 지난 뒤에야 스플래시 링을 띄운다.
                        await WidgetsBinding.instance.endOfFrame;
                        if (mounted) setState(() => _webViewAttached = true);
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
                  showRing: _webViewAttached,
                  onHidden: () => setState(() => _splashGone = true),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// OS 스플래시가 걷힌 자리에 같은 고래를 멈춘 채 두고 둘레에 로딩 링을 돌리다가, 첫 페이지가 뜨면 페이드 아웃한다.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({
    super.key,
    required this.visible,
    required this.showRing,
    required this.onHidden,
  });

  final bool visible;
  final bool showRing;
  final VoidCallback onHidden;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> {
  bool _precaching = false;
  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_precaching) {
      _precaching = true;
      precacheImage(splashLogo, context).whenComplete(() {
        WidgetsBinding.instance.allowFirstFrame();
        // 첫 프레임은 링 없이 OS 스플래시와 똑같이 나가고, 링은 그 뒤로 페이드인한다.
        if (mounted) setState(() => _precached = true);
      });
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Image(
                    image: splashLogo,
                    width: splashLogoSize,
                    height: splashLogoSize,
                  ),
                  // 기본 링은 동작 줄이기와 상관없이 계속 돌기 때문에 직접 숨긴다.
                  // 웹뷰가 화면 합성에 처음 붙을 때 링이 불투명하게 비치거나 잠깐 사라졌다(Android 에뮬레이터).
                  // 그래서 웹뷰가 붙은 뒤(showRing)에야 트리에 넣고 페이드인한다.
                  if (_precached &&
                      widget.showRing &&
                      !MediaQuery.disableAnimationsOf(context))
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 200),
                      builder: (_, opacity, child) =>
                          Opacity(opacity: opacity, child: child),
                      child: SizedBox.square(
                        dimension: splashRingSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: splashWhale,
                          backgroundColor: splashWhale.withValues(alpha: 0.15),
                          semanticsLabel: '불러오는 중',
                        ),
                      ),
                    ),
                ],
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
