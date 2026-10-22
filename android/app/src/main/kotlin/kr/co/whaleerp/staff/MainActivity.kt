package kr.co.whaleerp.staff

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 12+ 기본 종료 애니메이션은 고래를 먼저 지우고 화면을 페이드한다.
        // 같은 자리에 Flutter 회전 스플래시가 이어지므로 애니메이션 없이 바로 걷는다.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { it.remove() }
        }
    }
}
