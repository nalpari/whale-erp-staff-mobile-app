package kr.co.whaleerp.staff

import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.security.MessageDigest

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
        // flush 는 디스크 쓰기가 끝날 때까지 부른 스레드를 막고, onInactive(알림창 · 권한 창)에서도 불리므로
        // 메인 스레드가 아닌 백그라운드 작업 큐에서 처리한다.
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(
            messenger,
            "kr.co.whaleerp.staff/cookies",
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler { call, result ->
                if (call.method == "flush") {
                    CookieManager.getInstance().flush()
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
        // 기기 식별자(계획 결정 9). ANDROID_ID 는 Android 8 이상에서 앱 서명 키 · 사용자별로 정해져 앱을 다시 깔아도 같다(7 이하는 기기 하나에 하나). 원래 값은 앱 밖으로 내보내지
        // 않고, 앞말을 붙여 SHA-256 으로 바꾼 64자 16진수만 돌려준다(iOS AppDelegate 와 같은 방식). 읽지 못하면 null.
        MethodChannel(messenger, "kr.co.whaleerp.staff/device").setMethodCallHandler { call, result ->
            if (call.method == "deviceId") {
                val raw = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                result.success(if (raw.isNullOrBlank()) null else hashDeviceId(raw))
            } else {
                result.notImplemented()
            }
        }
    }

    private fun hashDeviceId(raw: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("whale-staff-device:$raw".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
