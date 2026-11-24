import CryptoKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 기기 식별자(계획 결정 9). identifierForVendor 는 같은 회사 앱이 하나라도 남아 있으면 다시 깔아도 같다. 원래 값은 앱 밖으로
    // 내보내지 않고, 앞말을 붙여 SHA-256 으로 바꾼 64자 16진수만 돌려준다(Android MainActivity 와 같은 방식). 읽지 못하면 nil.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WhaleDeviceId") {
      let channel = FlutterMethodChannel(name: "kr.co.whaleerp.staff/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "deviceId" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let raw = UIDevice.current.identifierForVendor?.uuidString else {
          result(nil)
          return
        }
        let digest = SHA256.hash(data: Data("whale-staff-device:\(raw)".utf8))
        result(digest.map { String(format: "%02x", $0) }.joined())
      }
    }
  }
}
