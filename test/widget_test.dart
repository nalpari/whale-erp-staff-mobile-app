import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:staff/main.dart';

void main() {
  final base = Uri.parse('https://staff-dev.whaleerp.co.kr');

  test('같은 호스트와 웹뷰 내부 스킴은 앱에서 연다', () {
    expect(
      isInApp(Uri.parse('https://staff-dev.whaleerp.co.kr/login'), base),
      isTrue,
    );
    expect(isInApp(Uri.parse('about:blank'), base), isTrue);
  });

  test('다른 호스트와 tel·mailto 는 밖에서 연다', () {
    expect(isInApp(Uri.parse('https://google.com'), base), isFalse);
    expect(isInApp(Uri.parse('tel:01012345678'), base), isFalse);
    expect(isInApp(Uri.parse('mailto:a@b.com'), base), isFalse);
  });

  test('User-Agent 접미사는 WhaleStaffApp/<앱 버전>', () {
    expect(appUserAgent('1.0.0'), 'WhaleStaffApp/1.0.0');
  });

  group('readAppVersion', () {
    PackageInfo info(String version) => PackageInfo(
      appName: 'staff',
      packageName: 'kr.co.whaleerp.staff',
      version: version,
      buildNumber: '1',
    );

    test('읽은 버전을 그대로 돌려준다', () async {
      expect(await readAppVersion(() async => info('1.0.0')), '1.0.0');
    });

    test('버전이 비어 있으면 unknown', () async {
      expect(await readAppVersion(() async => info('')), 'unknown');
    });

    test('읽다가 실패해도 앱이 뜨도록 unknown 을 돌려준다', () async {
      expect(
        await readAppVersion(() async => throw Exception('채널 오류')),
        'unknown',
      );
    });

    testWidgets('응답이 없으면 2초 뒤 unknown 을 돌려주고 오류를 보고한다', (tester) async {
      String? version;
      readAppVersion(() => Completer<PackageInfo>().future)
          .then((v) => version = v);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(version, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(version, 'unknown');
      expect(tester.takeException(), isA<TimeoutException>());
    });
  });

  test('위치는 웹 주소와 같은 출처(https · 호스트 · 포트)만 허락한다', () {
    expect(
      isTrustedOrigin('https://staff-dev.whaleerp.co.kr:443', base),
      isTrue,
    );
    expect(
      isTrustedOrigin('https://staff-dev.whaleerp.co.kr:8443', base),
      isFalse,
    );
    expect(
      isTrustedOrigin(
        'https://staff-dev.whaleerp.co.kr',
        Uri.parse('http://staff-dev.whaleerp.co.kr'),
      ),
      isFalse,
    );
    expect(isTrustedOrigin('https://staff-dev.whaleerp.co.kr', base), isTrue);
    expect(isTrustedOrigin('https://staff-dev.whaleerp.co.kr/', base), isTrue);
    expect(isTrustedOrigin('http://staff-dev.whaleerp.co.kr', base), isFalse);
    expect(isTrustedOrigin('https://evil.example.com', base), isFalse);
    expect(
      isTrustedOrigin('https://staff-dev.whaleerp.co.kr.evil.com', base),
      isFalse,
    );
    expect(isTrustedOrigin('', base), isFalse);
  });

  group('ensureLocationAccess', () {
    // 호출 횟수를 센다. 단계 안에서 fail() 을 쓰면 오류 처리(guarded)가 삼켜 버리므로 쓰지 않는다.
    late Map<String, int> calls;
    setUp(() => calls = {});
    Future<T> Function() counted<T>(String name, T value) => () async {
      calls[name] = (calls[name] ?? 0) + 1;
      return value;
    };
    int called(String name) => calls[name] ?? 0;
    final precise = LocationAccuracyStatus.precise;
    final reduced = LocationAccuracyStatus.reduced;

    test('이미 정확한 위치까지 허락이면 묻지 않고 precise', () async {
      for (final p in [
        LocationPermission.whileInUse,
        LocationPermission.always,
      ]) {
        expect(
          await ensureLocationAccess(
            check: counted('check', p),
            request: counted('request', p),
            accuracy: counted('accuracy', precise),
            serviceEnabled: counted('service', true),
          ),
          LocationAccess.precise,
        );
      }
      expect(called('request'), 0);
    });

    test('denied 면 한 번 묻고 허락이면 precise', () async {
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.denied),
          request: counted('request', LocationPermission.whileInUse),
          accuracy: counted('accuracy', precise),
          serviceEnabled: counted('service', true),
        ),
        LocationAccess.precise,
      );
      expect(called('request'), 1);
    });

    test('물었는데 거부면 denied 이고 위치 서비스 · 정확도는 보지 않는다', () async {
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.denied),
          request: counted('request', LocationPermission.denied),
          accuracy: counted('accuracy', precise),
          serviceEnabled: counted('service', true),
        ),
        LocationAccess.denied,
      );
      expect(called('request'), 1);
      expect(called('service'), 0);
      expect(called('accuracy'), 0);
    });

    test('Android 영구 거부는 요청 결과로 deniedForever 가 된다', () async {
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.denied),
          request: counted('request', LocationPermission.deniedForever),
          accuracy: counted('accuracy', precise),
          serviceEnabled: counted('service', true),
        ),
        LocationAccess.deniedForever,
      );
      expect(called('service'), 0);
    });

    test('영구 거부 · 판단 불가면 묻지 않는다', () async {
      for (final (p, want) in [
        (LocationPermission.deniedForever, LocationAccess.deniedForever),
        (LocationPermission.unableToDetermine, LocationAccess.denied),
      ]) {
        expect(
          await ensureLocationAccess(
            check: counted('check', p),
            request: counted('request', LocationPermission.whileInUse),
            accuracy: counted('accuracy', precise),
            serviceEnabled: counted('service', true),
          ),
          want,
        );
      }
      expect(called('request'), 0);
      expect(called('service'), 0);
      expect(called('accuracy'), 0);
    });

    test('기기 위치가 꺼져 있으면 serviceDisabled 이고 정확도는 보지 않는다', () async {
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.whileInUse),
          request: counted('request', LocationPermission.whileInUse),
          accuracy: counted('accuracy', precise),
          serviceEnabled: counted('service', false),
        ),
        LocationAccess.serviceDisabled,
      );
      expect(called('accuracy'), 0);
    });

    test('이미 대략적 위치면 알린 뒤 한 번 더 묻고, 정확한 위치로 바꾸면 precise', () async {
      final order = <String>[];
      var status = reduced;
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.whileInUse),
          request: () async {
            order.add('request');
            status = precise;
            return LocationPermission.whileInUse;
          },
          accuracy: () async => status,
          serviceEnabled: counted('service', true),
          onAskPrecise: () => order.add('notify'),
        ),
        LocationAccess.precise,
      );
      expect(order, ['notify', 'request']);
    });

    test('대략적 위치를 유지하면 approximate', () async {
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.whileInUse),
          request: counted('request', LocationPermission.whileInUse),
          accuracy: counted('accuracy', reduced),
          serviceEnabled: counted('service', true),
        ),
        LocationAccess.approximate,
      );
      expect(called('request'), 1);
    });

    test('askPrecise 가 꺼져 있으면 다시 묻지 않는다', () async {
      var notified = 0;
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.whileInUse),
          request: counted('request', LocationPermission.whileInUse),
          accuracy: counted('accuracy', reduced),
          serviceEnabled: counted('service', true),
          askPrecise: false,
          onAskPrecise: () => notified++,
        ),
        LocationAccess.approximate,
      );
      expect(called('request'), 0);
      expect(notified, 0);
    });

    test('방금 창에서 대략적 위치를 골랐으면 바로 다시 묻지 않는다', () async {
      var notified = 0;
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.denied),
          request: counted('request', LocationPermission.whileInUse),
          accuracy: counted('accuracy', reduced),
          serviceEnabled: counted('service', true),
          onAskPrecise: () => notified++,
        ),
        LocationAccess.approximate,
      );
      expect(called('request'), 1);
      expect(notified, 0);
    });

    test('재요청 결과가 거부로 바뀌었으면 그 상태를 따른다', () async {
      var first = true;
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.whileInUse),
          request: () async {
            first = false;
            return LocationPermission.deniedForever;
          },
          accuracy: () async => first ? reduced : precise,
          serviceEnabled: counted('service', true),
        ),
        LocationAccess.deniedForever,
      );
    });

    testWidgets('권한 확인이 실패하면 failed 를 돌려주고 오류를 보고한다', (tester) async {
      final access = await ensureLocationAccess(
        check: () async => throw Exception('activity 없음'),
        request: counted('request', LocationPermission.whileInUse),
        accuracy: counted('accuracy', precise),
        serviceEnabled: counted('service', true),
      );
      expect(access, LocationAccess.failed);
      expect(tester.takeException(), isA<Exception>());
      expect(called('service'), 0);
    });

    testWidgets('권한 창 결과가 오지 않으면 시간 초과 뒤 failed', (tester) async {
      LocationAccess? access;
      ensureLocationAccess(
        check: counted('check', LocationPermission.denied),
        request: () => Completer<LocationPermission>().future,
        accuracy: counted('accuracy', precise),
        serviceEnabled: counted('service', true),
      ).then((v) => access = v);
      await tester.pump(const Duration(seconds: 59));
      expect(access, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(access, LocationAccess.failed);
      expect(tester.takeException(), isA<TimeoutException>());
    });

    testWidgets('권한 확인이 시간을 넘긴 뒤 늦게 denied 로 끝나도 권한 창을 띄우지 않는다', (
      tester,
    ) async {
      final slowCheck = Completer<LocationPermission>();
      LocationAccess? access;
      ensureLocationAccess(
        check: () => slowCheck.future,
        request: counted('request', LocationPermission.whileInUse),
        accuracy: counted('accuracy', precise),
        serviceEnabled: counted('service', true),
      ).then((v) => access = v);
      await tester.pump(const Duration(seconds: 60));
      expect(access, LocationAccess.failed);
      expect(tester.takeException(), isA<TimeoutException>());
      slowCheck.complete(LocationPermission.denied);
      await tester.pump();
      expect(called('request'), 0);
    });

    testWidgets('권한이 있는데 위치 서비스 상태를 못 읽으면 켜진 것으로 보고 허락한다', (tester) async {
      final access = await ensureLocationAccess(
        check: counted('check', LocationPermission.whileInUse),
        request: counted('request', LocationPermission.whileInUse),
        accuracy: counted('accuracy', precise),
        serviceEnabled: () async => throw Exception('서비스 확인 실패'),
      );
      expect(access, LocationAccess.precise);
      expect(tester.takeException(), isA<Exception>());
    });

    testWidgets('권한이 있는데 정확도를 못 읽으면 정확한 것으로 보고 허락한다', (tester) async {
      final access = await ensureLocationAccess(
        check: counted('check', LocationPermission.whileInUse),
        request: counted('request', LocationPermission.whileInUse),
        accuracy: () async => throw Exception('정확도 확인 실패'),
        serviceEnabled: counted('service', true),
      );
      expect(access, LocationAccess.precise);
      expect(tester.takeException(), isA<Exception>());
      expect(called('request'), 0);
    });

    testWidgets('정확한 위치 재요청이 실패하면 approximate 로 두고 오류를 보고한다', (tester) async {
      var notified = 0;
      final access = await ensureLocationAccess(
        check: counted('check', LocationPermission.whileInUse),
        request: () async => throw Exception('재요청 실패'),
        accuracy: counted('accuracy', reduced),
        serviceEnabled: counted('service', true),
        onAskPrecise: () => notified++,
      );
      expect(access, LocationAccess.approximate);
      expect(notified, 1);
      expect(tester.takeException(), isA<Exception>());
    });

    testWidgets('정확한 위치 재요청이 끝나지 않으면 기본 60초 뒤 approximate', (tester) async {
      LocationAccess? access;
      ensureLocationAccess(
        check: counted('check', LocationPermission.whileInUse),
        request: () => Completer<LocationPermission>().future,
        accuracy: counted('accuracy', reduced),
        serviceEnabled: counted('service', true),
      ).then((v) => access = v);
      await tester.pump(const Duration(seconds: 59));
      expect(access, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(access, LocationAccess.approximate);
      expect(tester.takeException(), isA<TimeoutException>());
    });
  });

  group('LocationGate', () {
    test('진행 중이면 같은 결과를 기다리고, 안내는 시작한 쪽만 띄운다', () async {
      var runs = 0;
      final done = Completer<LocationAccess>();
      final gate = LocationGate(({required askPrecise, onAskPrecise}) {
        runs++;
        return done.future;
      });
      final a = gate.request();
      final b = gate.request();
      done.complete(LocationAccess.approximate);
      final ra = await a;
      final rb = await b;
      expect(runs, 1);
      expect(ra, (access: LocationAccess.approximate, started: true));
      expect(rb, (access: LocationAccess.approximate, started: false));
    });

    test('끝난 뒤에는 새로 확인하고, 정확한 위치는 다시 물은 뒤로는 묻지 않는다', () async {
      final asks = <bool>[];
      final gate = LocationGate(({required askPrecise, onAskPrecise}) async {
        asks.add(askPrecise);
        if (askPrecise) onAskPrecise?.call();
        return LocationAccess.approximate;
      });
      await gate.request();
      await gate.request();
      expect(asks, [true, false]);
    });

    test('정확한 위치를 묻지 않았으면 다음에도 물을 수 있다', () async {
      final asks = <bool>[];
      final gate = LocationGate(({required askPrecise, onAskPrecise}) async {
        asks.add(askPrecise);
        return LocationAccess.precise;
      });
      await gate.request();
      await gate.request();
      expect(asks, [true, true]);
    });
  });

  test('웹 허락과 안내는 위치 상태를 따른다', () {
    expect(LocationAccess.precise.allowsWeb, isTrue);
    expect(LocationAccess.approximate.allowsWeb, isTrue);
    expect(LocationAccess.serviceDisabled.allowsWeb, isTrue);
    expect(LocationAccess.denied.allowsWeb, isFalse);
    expect(LocationAccess.deniedForever.allowsWeb, isFalse);
    expect(LocationAccess.failed.allowsWeb, isFalse);

    expect(locationGuide(LocationAccess.precise), isNull);
    expect(locationGuide(LocationAccess.denied), isNull);
    final approximate = locationGuide(LocationAccess.approximate)!;
    expect((approximate.action, approximate.appSettings), ('설정', true));
    final forever = locationGuide(LocationAccess.deniedForever)!;
    expect((forever.action, forever.appSettings), ('설정', true));
    final service = locationGuide(LocationAccess.serviceDisabled)!;
    expect((service.action, service.appSettings), ('위치 켜기', false));
    expect(locationGuide(LocationAccess.failed)!.action, isNull);
  });

  group('allowGeolocation', () {
    test('믿지 않는 출처면 OS 권한을 묻지 않고 거부한다', () async {
      expect(
        await allowGeolocation(
          'https://evil.example.com',
          base,
          () => fail('OS 권한을 묻지 않아야 한다'),
        ),
        isFalse,
      );
    });

    test('믿는 출처면 OS 권한 결과를 따른다', () async {
      const origin = 'https://staff-dev.whaleerp.co.kr';
      expect(await allowGeolocation(origin, base, () async => true), isTrue);
      expect(await allowGeolocation(origin, base, () async => false), isFalse);
    });
  });
}
