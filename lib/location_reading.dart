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

/// 권한 확인 전체(권한 창 · 정확한 위치 재요청 포함)의 상한. 권한 확인 단계마다 60초 제한이 따로 걸려 있어,
/// 전체를 묶지 않으면 이론상 75초를 넘을 수 있다. 최악의 합계: 권한 60초 + 측정 9초 + 잰 뒤 확인(정확도 · 권한 재확인 ·
/// 위치 서비스) 최대 4초 = 73초로, 웹이 기다리는 75초 안에 든다.
const permissionTimeLimit = Duration(seconds: 60);

/// 잰 뒤에 정확도 · 권한 · 위치 서비스를 한 번 더 읽을 때의 제한.
const _followUpTimeLimit = Duration(seconds: 2);

/// 브리지 `measureLocation`: 권한을 확인하고(필요하면 묻고) 지금 위치를 한 번 새로 재어, 좌표와 모의 위치 여부를
/// 같은 측정값에서 함께 돌려준다(계획 결정 8). 모양은 웹 출퇴근 화면의 위치 상태(ok · denied · unavailable)에 맞춘다.
///
/// - `{status: 'ok', latitude, longitude, accuracyMeters, mocked, precise}`
///   - `accuracyMeters`: 운영체제가 정확도를 알려 주지 않으면(0 이하) null.
///   - `mocked`: 운영체제가 알려 준 모의 위치 여부(Android `isMock`/`isFromMockProvider`, iOS `isSimulatedBySoftware`).
///   - `precise`: 잰 뒤 정확도 설정을 새로 읽는다. false 면 「대략적 위치」(Android 대략적 위치 · iOS 정확한 위치 끔)라
///     반경 판정이 틀릴 수 있다(판정은 그대로 하고 안내만 한다). 정확도 설정을 읽지 못하면 null.
/// - `{status: 'denied'}`: 위치 권한 거부(영구 거부 포함). 측정 중에 권한을 빼앗긴 경우도 포함한다.
/// - `{status: 'unavailable', reason}`: 기기 위치 꺼짐(serviceDisabled), 권한 확인 실패(permissionCheckFailed),
///   권한 확인이 [permissionTimeLimit] 를 넘김(permissionTimeout), 측정 시간 초과(timeout), 그 밖의 측정 오류(error).
///
/// 마지막으로 알던 위치(lastKnown)는 쓰지 않는다. 판정에 쓰는 위치는 버튼을 누를 때 새로 읽는다(출근 및 퇴근 기록 명세).
Future<Map<String, Object?>> measureLocation({
  required Future<LocationAccess> Function() ensureAccess,
  required Future<Position> Function() currentPosition,
  Future<LocationAccuracyStatus> Function() accuracy =
      Geolocator.getLocationAccuracy,
  Future<LocationPermission> Function() checkPermission =
      Geolocator.checkPermission,
  Future<bool> Function() serviceEnabled = Geolocator.isLocationServiceEnabled,
  Duration permissionTimeout = permissionTimeLimit,
}) async {
  final LocationAccess access;
  try {
    access = await ensureAccess().timeout(permissionTimeout);
  } on TimeoutException catch (e, s) {
    _report(e, s, '위치 권한 확인이 ${permissionTimeout.inSeconds}초를 넘김');
    return {'status': 'unavailable', 'reason': 'permissionTimeout'};
  } catch (e, s) {
    _report(e, s, '위치 권한을 확인하지 못함');
    return {'status': 'unavailable', 'reason': 'permissionCheckFailed'};
  }
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
    // iOS 는 시간이 넘어도 플러그인이 네이티브 측정을 멈추지 않는다(답만 끊는다).
    final position = await currentPosition().timeout(
      measureTimeLimit + const Duration(seconds: 1),
    );
    return {
      'status': 'ok',
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracyMeters': position.accuracy > 0 ? position.accuracy : null,
      'mocked': position.isMocked,
      'precise': await _readPrecise(accuracy),
    };
  } on TimeoutException {
    // Android 는 고정밀 위치가 꺼진 기기에서 「위치 정확도 켜기」 시스템 창을 띄울 수 있다.
    // 사용자가 그 창을 보는 사이 시간이 넘으면 여기로 온다(알려진 한계, 다시 누르면 된다).
    return {'status': 'unavailable', 'reason': 'timeout'};
  } on LocationServiceDisabledException {
    return {'status': 'unavailable', 'reason': 'serviceDisabled'};
  } on PermissionDeniedException {
    return {'status': 'denied'};
  } catch (e, s) {
    // iOS 는 측정 중에 권한을 빼앗기거나 기기 위치를 끄면 PermissionDeniedException 이 아니라 일반 측정 오류로 온다.
    // 권한을 다시 읽어 나누고, 거부로 보이면 위치 서비스도 읽어 「위치 꺼짐」과 가른다(iOS 는 위치를 끄면 권한이 거부로 보인다).
    if (await _permissionRevoked(checkPermission)) {
      return await _serviceOff(serviceEnabled)
          ? {'status': 'unavailable', 'reason': 'serviceDisabled'}
          : {'status': 'denied'};
    }
    _report(e, s, '위치를 재지 못함');
    return {'status': 'unavailable', 'reason': 'error'};
  }
}

/// 정확도 설정이 정확한 위치인지. 읽지 못하면 null(웹이 accuracyMeters 로 판단하게).
Future<bool?> _readPrecise(
  Future<LocationAccuracyStatus> Function() accuracy,
) async {
  try {
    return await accuracy().timeout(_followUpTimeLimit) ==
        LocationAccuracyStatus.precise;
  } catch (e, s) {
    _report(e, s, '위치 정확도 설정을 읽지 못해 precise 를 null 로 보냄');
    return null;
  }
}

Future<bool> _permissionRevoked(
  Future<LocationPermission> Function() checkPermission,
) async {
  try {
    final permission = await checkPermission().timeout(_followUpTimeLimit);
    return permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever;
  } catch (e, s) {
    _report(e, s, '측정 실패 뒤 위치 권한을 다시 읽지 못해 error 로 보냄');
    return false;
  }
}

/// 위치 서비스가 꺼졌는지. 읽지 못하면 꺼지지 않은 것으로 본다(거부로 둔다).
Future<bool> _serviceOff(Future<bool> Function() serviceEnabled) async {
  try {
    return !await serviceEnabled().timeout(_followUpTimeLimit);
  } catch (e, s) {
    _report(e, s, '측정 실패 뒤 위치 서비스 상태를 읽지 못해 denied 로 보냄');
    return false;
  }
}

void _report(Object e, StackTrace s, String context) =>
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'location_reading',
        context: ErrorDescription(context),
      ),
    );

/// 지금 위치를 높은 정확도로 한 번 새로 읽는다. [measureTimeLimit] 안에 못 읽으면 TimeoutException.
Future<Position> readCurrentPosition() => Geolocator.getCurrentPosition(
  locationSettings: const LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: measureTimeLimit,
  ),
);
