package kr.co.whaleerp.staff

import android.os.Build
import android.os.Bundle
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 12+ 기본 종료 애니메이션은 고래를 먼저 지우고 화면을 페이드한다.
        // 같은 자리에 Flutter 회전 스플래시가 이어지므로 애니메이션 없이 바로 걷는다.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { it.remove() }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 웹뷰 쿠키를 디스크에 쓰고 바로 답한다. flutter_inappwebview_android 1.2.0-beta.3 의 flush 는 성공해도 답을
        // 돌려주지 않아, 앱을 내릴 때마다 답을 기다리는 콜백이 엔진에 남았다(PR #8 pr-agent 리뷰).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kr.co.whaleerp.staff/cookies")
            .setMethodCallHandler { call, result ->
                if (call.method == "flush") {
                    CookieManager.getInstance().flush()
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
    }
}
