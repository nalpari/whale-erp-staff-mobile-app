import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// 위치를 쓸 수 있는 상태. 웹의 위치 요청을 허락할지와 사용자에게 띄울 안내를 정한다.
/// (main.dart 의 권한 확인 `ensureLocationAccess` 가 돌려준다.)
enum LocationAccess {
  /// 정확한 위치로 허락.
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

/// 위치를 한 번 재는 데 쓰는 시간 제한. 권한 확인이 끝난 뒤부터 센다.
const measureTimeLimit = Duration(seconds: 8);

/// 브리지 `measureLocation`: 권한을 확인하고(필요하면 묻고) 지금 위치를 한 번 새로 재어, 좌표와 모의 위치 여부를
/// 같은 측정값에서 함께 돌려준다(계획 결정 8). 모양은 웹 출퇴근 화면의 위치 상태(ok · denied · unavailable)에 맞춘다.
///
/// - `{status: 'ok', latitude, longitude, accuracyMeters, mocked, precise}`
///   - `mocked`: 운영체제가 알려 준 모의 위치 여부(Android `isMock`/`isFromMockProvider`, iOS `isSimulatedBySoftware`).
///   - `precise`: false 면 「대략적 위치」라 반경 판정이 틀릴 수 있다(판정은 그대로 하고 안내만 한다).
/// - `{status: 'denied'}`: 위치 권한 거부(영구 거부 포함).
/// - `{status: 'unavailable', reason}`: 기기 위치 꺼짐(serviceDisabled), 권한 확인 실패(permissionCheckFailed),
///   시간 초과(timeout), 그 밖의 측정 오류(error).
///
/// 마지막으로 알던 위치(lastKnown)는 쓰지 않는다. 판정에 쓰는 위치는 버튼을 누를 때 새로 읽는다(출근 및 퇴근 기록 명세).
Future<Map<String, Object?>> measureLocation({
  required Future<LocationAccess> Function() ensureAccess,
  required Future<Position> Function() currentPosition,
}) async {
  final access = await ensureAccess();
  switch (access) {
    case LocationAccess.denied || LocationAccess.deniedForever:
      return {'status': 'denied'};
    case LocationAccess.serviceDisabled:
      return {'status': 'unavailable', 'reason': 'serviceDisabled'};
    case LocationAccess.failed:
      return {'status': 'unavailable', 'reason': 'permissionCheckFailed'};
    case LocationAccess.precise || LocationAccess.approximate:
      break;
  }
  try {
    final position = await currentPosition().timeout(
      measureTimeLimit + const Duration(seconds: 1),
    );
    return {
      'status': 'ok',
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracyMeters': position.accuracy,
      'mocked': position.isMocked,
      'precise': access == LocationAccess.precise,
    };
  } on TimeoutException {
    return {'status': 'unavailable', 'reason': 'timeout'};
  } on LocationServiceDisabledException {
    return {'status': 'unavailable', 'reason': 'serviceDisabled'};
  } on PermissionDeniedException {
    return {'status': 'denied'};
  } catch (e, s) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'location_reading',
        context: ErrorDescription('위치를 재지 못함'),
      ),
    );
    return {'status': 'unavailable', 'reason': 'error'};
  }
}

/// 지금 위치를 높은 정확도로 한 번 새로 읽는다. [measureTimeLimit] 안에 못 읽으면 TimeoutException.
Future<Position> readCurrentPosition() => Geolocator.getCurrentPosition(
  locationSettings: const LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: measureTimeLimit,
  ),
);
