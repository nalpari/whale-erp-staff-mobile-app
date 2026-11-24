import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:staff/location_reading.dart';
import 'package:staff/main.dart';
import 'package:staff/native_bridge.dart';

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

  group('deviceIdHandler', () {
    final hex = 'a' * 64;
    test('64자 16진수 해시를 deviceId 로 돌려준다', () async {
      expect(await deviceIdHandler(() async => hex)([]), {'deviceId': hex});
    });

    test('못 읽었거나 해시 모양이 아니면 실패한다(원래 값이 새지 않게)', () async {
      await expectLater(
        deviceIdHandler(() async => null)([]),
        throwsStateError,
      );
      await expectLater(
        deviceIdHandler(() async => '9774d56d682e549c')([]),
        throwsStateError,
      );
      await expectLater(
        deviceIdHandler(() async => 'A' * 64)([]),
        throwsStateError,
      );
    });

    testWidgets('2초 안에 답이 없으면 실패한다', (tester) async {
      Object? error;
      Future(() => deviceIdHandler(() => Completer<String?>().future)([]))
          .then((f) => f)
          .catchError((Object e) => error = e);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(error, isA<TimeoutException>());
    });
  });

  group('pullToRefreshHandler', () {
    test('참 · 거짓 인자로 당겨서 새로고침을 켜고 끈다', () async {
      final calls = <bool>[];
      final handler = pullToRefreshHandler(calls.add);
      expect(await handler([false]), isNull);
      expect(await handler([true]), isNull);
      expect(calls, [false, true]);
    });

    test('인자가 참 · 거짓이 아니면 끄지 않고 실패한다', () async {
      final calls = <bool>[];
      final handler = pullToRefreshHandler(calls.add);
      await expectLater(() async => handler([]), throwsArgumentError);
      await expectLater(() async => handler(['false']), throwsArgumentError);
      expect(calls, isEmpty);
    });
  });

  group('flushCookies', () {
    testWidgets('Android 는 쿠키를 디스크에 쓰고 보고하지 않는다', (tester) async {
      var flushed = 0;
      await flushCookies(
        platform: TargetPlatform.android,
        flush: () async => flushed++,
      );
      expect(flushed, 1);
      expect(tester.takeException(), isNull);
    });

    test('iOS 는 웹뷰가 스스로 저장하므로 부르지 않는다', () async {
      var flushed = 0;
      await flushCookies(
        platform: TargetPlatform.iOS,
        flush: () async => flushed++,
      );
      expect(flushed, 0);
    });

    testWidgets('실패하면 예외를 밖으로 내지 않고 보고한다', (tester) async {
      await flushCookies(
        platform: TargetPlatform.android,
        flush: () async => throw PlatformException(code: '채널 오류'),
      );
      expect(tester.takeException(), isA<PlatformException>());
    });

    testWidgets('응답이 없으면 2초 뒤 끝내고 시간 초과를 보고한다', (tester) async {
      var done = false;
      flushCookies(
        platform: TargetPlatform.android,
        flush: () => Completer<void>().future,
      ).then((_) => done = true);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(done, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(done, isTrue);
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

  testWidgets('권한 창이 결과 없이 시간을 넘기면 다음 요청은 권한을 새로 요청한다', (tester) async {
    // geolocator(Android)는 창이 취소되면 결과를 돌려주지 않는다. 앞 요청을 기다리면 다시 시도할 수 없다.
    var requests = 0;
    final answers = [
      Completer<LocationPermission>().future,
      Future.value(LocationPermission.whileInUse),
    ];
    Future<LocationAccess> ask() => ensureLocationAccess(
      check: () async => LocationPermission.denied,
      request: () => answers[requests++],
      accuracy: () async => LocationAccuracyStatus.precise,
      serviceEnabled: () async => true,
    );
    LocationAccess? first;
    ask().then((v) => first = v);
    await tester.pump(const Duration(seconds: 60));
    expect(first, LocationAccess.failed);
    expect(tester.takeException(), isA<TimeoutException>());
    expect(await ask(), LocationAccess.precise);
    expect(requests, 2);
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

    // 부를 때마다 [step] 씩 흐르는 가짜 시계.
    DateTime Function() ticking(Duration step) {
      var at = DateTime(2026, 11, 23, 9);
      return () => at = at.add(step);
    }

    testWidgets('확인이 늦게 끝나 창을 띄울 시간이 지났으면 권한 창을 띄우지 않고 failed', (tester) async {
      final access = await ensureLocationAccess(
        check: counted('check', LocationPermission.denied),
        request: counted('request', LocationPermission.whileInUse),
        accuracy: counted('accuracy', precise),
        serviceEnabled: counted('service', true),
        askWithin: const Duration(seconds: 58),
        now: ticking(const Duration(seconds: 59)),
      );
      expect(access, LocationAccess.failed);
      expect(called('request'), 0);
      expect(tester.takeException(), isA<TimeoutException>());
    });

    test('앞 단계가 늦어 창을 띄울 시간이 지났으면 정확한 위치를 다시 묻지 않고 approximate', () async {
      var asked = false;
      final access = await ensureLocationAccess(
        check: counted('check', LocationPermission.whileInUse),
        request: counted('request', LocationPermission.whileInUse),
        accuracy: counted('accuracy', reduced),
        serviceEnabled: counted('service', true),
        onAskPrecise: () => asked = true,
        askWithin: const Duration(seconds: 58),
        now: ticking(const Duration(seconds: 59)),
      );
      expect(access, LocationAccess.approximate);
      expect(called('request'), 0);
      expect(asked, isFalse);
    });

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
    test('iOS 에서 영구 거부로 보이는데 기기 위치가 꺼져 있으면 serviceDisabled', () async {
      for (final (ios, service, want) in [
        (true, false, LocationAccess.serviceDisabled),
        // 기기 위치가 켜져 있으면 진짜 영구 거부다. 위치를 켜라고 하면 사용자가 빠져나갈 수 없다.
        (true, true, LocationAccess.deniedForever),
        (false, false, LocationAccess.deniedForever),
      ]) {
        expect(
          await ensureLocationAccess(
            check: counted('check', LocationPermission.deniedForever),
            request: counted('request', LocationPermission.deniedForever),
            accuracy: counted('accuracy', precise),
            serviceEnabled: counted('service', service),
            onIOS: ios,
          ),
          want,
          reason: 'iOS=$ios service=$service',
        );
      }
      // 물었더니 영구 거부가 돌아온 경우도 같다.
      expect(
        await ensureLocationAccess(
          check: counted('check', LocationPermission.denied),
          request: counted('request', LocationPermission.deniedForever),
          accuracy: counted('accuracy', precise),
          serviceEnabled: counted('service', false),
          onIOS: true,
        ),
        LocationAccess.serviceDisabled,
      );
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

  group('NativeBridge', () {
    const origin = 'https://staff-dev.whaleerp.co.kr';
    // 막힌 호출이 기능을 부르지 않았는지(권한 창 · 측정 같은 부작용이 없는지) 세려고 테스트마다 새로 만든다.
    late int echoCalls;
    late NativeBridge bridge;
    setUp(() {
      echoCalls = 0;
      bridge = NativeBridge(
        base: base,
        handlers: {
          'echo': (args) {
            echoCalls++;
            return args;
          },
          'boom': (_) => throw StateError('x'),
          'asyncBoom': (_) async => throw StateError('y'),
          'appInfo': appInfoHandler(
            version: '1.0.0',
            platform: TargetPlatform.iOS,
          ),
        },
      );
    });

    test('같은 출처의 맨 위 화면 호출은 기능을 부르고 data 로 답한다', () async {
      expect(
        await bridge.handle(
          'echo',
          origin: origin,
          isMainFrame: true,
          args: [1, 'a'],
        ),
        {
          'ok': true,
          'data': [1, 'a'],
        },
      );
      expect(echoCalls, 1);
    });

    test('iframe 에서 온 호출은 기능을 부르지 않고 막는다', () async {
      expect(await bridge.handle('echo', origin: origin, isMainFrame: false), {
        'ok': false,
        'error': BridgeError.forbidden,
      });
      expect(echoCalls, 0);
    });

    test('다른 출처 · 다른 포트 · http 에서 온 호출은 기능을 부르지 않고 막는다', () async {
      for (final other in [
        'https://evil.example.com',
        'https://staff-dev.whaleerp.co.kr:8443',
        'http://staff-dev.whaleerp.co.kr',
        'null',
      ]) {
        expect(await bridge.handle('echo', origin: other, isMainFrame: true), {
          'ok': false,
          'error': BridgeError.forbidden,
        }, reason: other);
      }
      expect(echoCalls, 0);
    });

    test('등록되지 않은 이름은 막는다(실제로는 웹뷰 플러그인이 앱까지 보내지 않고 null 을 준다)', () async {
      expect(await bridge.handle('nope', origin: origin, isMainFrame: true), {
        'ok': false,
        'error': BridgeError.forbidden,
      });
    });

    testWidgets('기능이 예외를 던지면 failed 로 답하고 앱은 계속 돈다', (tester) async {
      expect(await bridge.handle('boom', origin: origin, isMainFrame: true), {
        'ok': false,
        'error': BridgeError.failed,
      });
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('비동기로 실패해도 failed 로 답한다', (tester) async {
      expect(
        await bridge.handle('asyncBoom', origin: origin, isMainFrame: true),
        {'ok': false, 'error': BridgeError.failed},
      );
      expect(tester.takeException(), isA<StateError>());
    });

    test('appInfo 는 버전과 운영체제를 돌려준다', () async {
      expect(
        await bridge.handle('appInfo', origin: origin, isMainFrame: true),
        {
          'ok': true,
          'data': {'version': '1.0.0', 'platform': 'ios'},
        },
      );
      for (final (platform, name) in [
        (TargetPlatform.android, 'android'),
        (TargetPlatform.linux, 'other'),
      ]) {
        expect(appInfoHandler(version: '1', platform: platform)(const []), {
          'version': '1',
          'platform': name,
        });
      }
    });
  });

  group('measureLocation', () {
    Position position({bool mocked = false}) => Position(
      latitude: 37.5,
      longitude: 127.0,
      timestamp: DateTime(2026, 11, 23),
      accuracy: 12,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: mocked,
    );

    Future<Map<String, Object?>> measure(
      LocationAccess access, {
      Future<Position> Function()? read,
      LocationAccuracyStatus accuracy = LocationAccuracyStatus.precise,
      LocationPermission permission = LocationPermission.whileInUse,
    }) => measureLocation(
      now: () => DateTime(2026, 11, 23),
      ensureAccess: () async => access,
      currentPosition: read ?? () async => position(),
      accuracy: () async => accuracy,
      checkPermission: () async => permission,
      serviceEnabled: () async => true,
    );

    test('대략적 위치면 새 위치를 기다리지 않는 읽기를 쓰고 위치 나이를 함께 보낸다', () async {
      var fresh = 0;
      final result = await measureLocation(
        now: () => DateTime(2026, 11, 23, 0, 5),
        ensureAccess: () async => LocationAccess.approximate,
        currentPosition: () async {
          fresh++;
          return position();
        },
        approximatePosition: () async => position(),
        // 잰 직후 사용자가 정확한 위치를 허락했어도 이 좌표는 대략적 위치다.
        accuracy: () async => LocationAccuracyStatus.precise,
      );
      expect(fresh, 0);
      expect(result['status'], 'ok');
      expect(result['ageSeconds'], 300);
      expect(result['precise'], isFalse);
    });

    test('정확한 위치면 새 위치 읽기를 쓴다', () async {
      var any = 0;
      final result = await measureLocation(
        now: () => DateTime(2026, 11, 23),
        ensureAccess: () async => LocationAccess.precise,
        currentPosition: () async => position(),
        approximatePosition: () async {
          any++;
          return position();
        },
        accuracy: () async => LocationAccuracyStatus.precise,
      );
      expect(any, 0);
      expect(result['ageSeconds'], 0);
    });

    test('정확한 위치면 좌표와 모의 여부를 같은 측정값에서 돌려준다', () async {
      expect(
        await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => LocationAccess.precise,
          currentPosition: () async => position(mocked: true),
          accuracy: () async => LocationAccuracyStatus.precise,
        ),
        {
          'status': 'ok',
          'latitude': 37.5,
          'longitude': 127.0,
          'accuracyMeters': 12.0,
          'ageSeconds': 0,
          'mocked': true,
          'precise': true,
        },
      );
    });

    test('대략적 위치도 재되 precise 를 false 로 알린다', () async {
      final result = await measure(
        LocationAccess.approximate,
        accuracy: LocationAccuracyStatus.reduced,
      );
      expect(result['status'], 'ok');
      expect(result['precise'], false);
      expect(result['mocked'], false);
    });

    test('권한이 없으면 재지 않고 denied', () async {
      var read = false;
      for (final access in [
        LocationAccess.denied,
        LocationAccess.deniedForever,
      ]) {
        expect(
          await measure(
            access,
            read: () async {
              read = true;
              return position();
            },
          ),
          {'status': 'denied'},
        );
      }
      expect(read, isFalse);
    });

    test('기기 위치 꺼짐 · 권한 확인 실패는 unavailable 과 이유', () async {
      expect(await measure(LocationAccess.serviceDisabled), {
        'status': 'unavailable',
        'reason': 'serviceDisabled',
      });
      expect(await measure(LocationAccess.failed), {
        'status': 'unavailable',
        'reason': 'permissionCheckFailed',
      });
    });

    testWidgets(
      '측정이 시간을 넘거나 위치가 꺼지면 unavailable, 측정 중 권한이 막히면 denied 이고 오류로 보고하지 않는다',
      (tester) async {
        expect(
          await measure(
            LocationAccess.precise,
            read: () async => throw TimeoutException('x'),
          ),
          {'status': 'unavailable', 'reason': 'timeout'},
        );
        expect(
          await measure(
            LocationAccess.precise,
            read: () async => throw const LocationServiceDisabledException(),
          ),
          {'status': 'unavailable', 'reason': 'serviceDisabled'},
        );
        expect(
          await measure(
            LocationAccess.precise,
            read: () async => throw const PermissionDeniedException('x'),
          ),
          {'status': 'denied'},
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('그 밖의 측정 오류는 보고하고 unavailable(error)', (tester) async {
      expect(
        await measure(
          LocationAccess.precise,
          read: () async => throw StateError('x'),
        ),
        {'status': 'unavailable', 'reason': 'error'},
      );
      expect(tester.takeException(), isA<StateError>());
    });
    testWidgets('정확도 설정을 읽지 못하면 precise 는 null(권한 확인의 대체값을 믿지 않는다)', (
      tester,
    ) async {
      final result = await measureLocation(
        now: () => DateTime(2026, 11, 23),
        ensureAccess: () async => LocationAccess.precise,
        currentPosition: () async => position(),
        accuracy: () async => throw StateError('정확도'),
      );
      expect(result['status'], 'ok');
      expect(result['precise'], isNull);
      expect(tester.takeException(), isA<StateError>());
    });

    test('정확도 값이 없으면(0) accuracyMeters 는 null', () async {
      final result = await measure(
        LocationAccess.precise,
        read: () async => Position(
          latitude: 1,
          longitude: 2,
          timestamp: DateTime(2026, 11, 23),
          accuracy: 0,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        ),
      );
      expect(result['accuracyMeters'], isNull);
    });

    testWidgets('측정이 끝나지 않으면 9초 뒤 timeout 으로 끊는다', (tester) async {
      Map<String, Object?>? result;
      measure(
        LocationAccess.precise,
        read: () => Completer<Position>().future,
      ).then((v) => result = v);
      await tester.pump(measureTimeLimit);
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(result, {'status': 'unavailable', 'reason': 'timeout'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('권한 확인이 상한을 넘기면 재지 않고 permissionTimeout', (tester) async {
      var read = false;
      Map<String, Object?>? result;
      measureLocation(
        now: () => DateTime(2026, 11, 23),
        ensureAccess: () => Completer<LocationAccess>().future,
        currentPosition: () async {
          read = true;
          return position();
        },
      ).then((v) => result = v);
      await tester.pump(permissionTimeLimit - const Duration(milliseconds: 1));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(result, {'status': 'unavailable', 'reason': 'permissionTimeout'});
      expect(read, isFalse);
      expect(tester.takeException(), isA<TimeoutException>());
    });

    testWidgets('권한 확인이 예외로 끝나면 보고하고 permissionCheckFailed', (tester) async {
      expect(
        await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => throw StateError('안내 실패'),
          currentPosition: () async => position(),
        ),
        {'status': 'unavailable', 'reason': 'permissionCheckFailed'},
      );
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('측정 중 일반 오류인데 권한이 사라졌으면 denied(iOS 권한 박탈)', (tester) async {
      expect(
        await measure(
          LocationAccess.precise,
          read: () async => throw const PositionUpdateException('denied'),
          permission: LocationPermission.deniedForever,
        ),
        {'status': 'denied'},
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('예상한 실패(꺼짐 · 거부 · 시간 초과)는 오류로 보고하지 않는다', (tester) async {
      await measure(LocationAccess.serviceDisabled);
      await measure(LocationAccess.denied);
      await measure(
        LocationAccess.precise,
        read: () async => throw TimeoutException('x'),
      );
      expect(tester.takeException(), isNull);
    });

    /// 테스트 안에서 보고된 오류를 모은다(여러 개가 보고되는 경로용).
    Future<List<Object>> collectErrors(Future<void> Function() body) async {
      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.exception);
      try {
        await body();
      } finally {
        FlutterError.onError = previous;
      }
      return errors;
    }

    test('잰 뒤 정확도 설정 읽기가 끝나지 않으면 2초 뒤 precise 는 null', () async {
      Map<String, Object?>? result;
      final errors = await collectErrors(() async {
        result = await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => LocationAccess.precise,
          currentPosition: () async => position(),
          accuracy: () => Completer<LocationAccuracyStatus>().future,
        );
      });
      expect(result?['status'], 'ok');
      expect(result?['precise'], isNull);
      expect(errors.single, isA<TimeoutException>());
    });

    test('측정 오류 뒤 권한 재확인이 끝나지 않으면 2초 뒤 error(거부로 둔갑하지 않는다)', () async {
      Map<String, Object?>? result;
      final errors = await collectErrors(() async {
        result = await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => LocationAccess.precise,
          currentPosition: () async => throw StateError('측정'),
          checkPermission: () => Completer<LocationPermission>().future,
        );
      });
      expect(result, {'status': 'unavailable', 'reason': 'error'});
      expect(errors.map((e) => e.runtimeType), [TimeoutException, StateError]);
    });

    test('측정 오류 뒤 권한 재확인이 실패해도 error 로 보고한다', () async {
      Map<String, Object?>? result;
      final errors = await collectErrors(() async {
        result = await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => LocationAccess.precise,
          currentPosition: () async => throw StateError('측정'),
          checkPermission: () async => throw StateError('권한'),
        );
      });
      expect(result, {'status': 'unavailable', 'reason': 'error'});
      expect(errors, hasLength(2));
    });

    testWidgets('측정 중 iOS 기기 위치를 끄면(권한이 거부로 보임) serviceDisabled', (
      tester,
    ) async {
      expect(
        await measureLocation(
          now: () => DateTime(2026, 11, 23),
          ensureAccess: () async => LocationAccess.precise,
          currentPosition: () async =>
              throw const PositionUpdateException('denied'),
          checkPermission: () async => LocationPermission.deniedForever,
          serviceEnabled: () async => false,
        ),
        {'status': 'unavailable', 'reason': 'serviceDisabled'},
      );
      expect(tester.takeException(), isNull);
    });

    test('최악의 시간 합계가 웹이 기다리는 75초보다 짧다', () {
      const followUps = Duration(seconds: 4);
      expect(
        permissionTimeLimit +
            measureTimeLimit +
            const Duration(seconds: 1) +
            followUps,
        lessThan(const Duration(seconds: 75)),
      );
    });
  });

  group('firstFreshPosition', () {
    final start = DateTime(2026, 11, 23, 9);
    Position at(DateTime time, {double latitude = 37.5}) => Position(
      latitude: latitude,
      longitude: 127.0,
      timestamp: time,
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

    test('측정 시작 전에 잰 옛 위치는 건너뛰고 다음 새 위치를 쓴다', () async {
      final stale = at(start.subtract(const Duration(minutes: 3)), latitude: 1);
      final fresh = at(start.add(const Duration(seconds: 1)), latitude: 2);
      final position = await firstFreshPosition(
        Stream.fromIterable([stale, fresh]),
        start,
      );
      expect(position.latitude, 2);
    });

    test('허용 오차(2초) 안의 위치는 새 위치로 본다', () async {
      final nearly = at(start.subtract(const Duration(seconds: 1)));
      expect(
        await firstFreshPosition(Stream.value(nearly), start),
        same(nearly),
      );
    });

    test('새 위치가 시간 안에 안 오면 TimeoutException 이고 구독을 끊는다', () async {
      var cancelled = false;
      final controller = StreamController<Position>(
        onCancel: () => cancelled = true,
      );
      addTearDown(controller.close);
      controller.add(at(start.subtract(const Duration(minutes: 3))));
      await expectLater(
        firstFreshPosition(
          controller.stream,
          start,
          timeLimit: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(cancelled, isTrue);
    });

    test('새 위치를 받거나 오류가 나도 구독을 끊는다', () async {
      var cancels = 0;
      final ok = StreamController<Position>(onCancel: () => cancels++);
      final failing = StreamController<Position>(onCancel: () => cancels++);
      addTearDown(ok.close);
      addTearDown(failing.close);
      final got = firstFreshPosition(ok.stream, start);
      ok.add(at(start));
      expect((await got).timestamp, start);
      final error = firstFreshPosition(failing.stream, start);
      failing.addError(const LocationServiceDisabledException());
      await expectLater(
        error,
        throwsA(isA<LocationServiceDisabledException>()),
      );
      expect(cancels, 2);
    });
  });
}
