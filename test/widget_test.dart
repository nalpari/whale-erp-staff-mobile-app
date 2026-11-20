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

  test('위치는 웹 주소와 같은 호스트의 https 출처만 허락한다', () {
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

  group('ensureLocationPermission', () {
    Future<LocationPermission> Function() returns(LocationPermission p) =>
        () async => p;

    test('이미 허락이면 묻지 않고 true', () async {
      var asked = 0;
      for (final p in [
        LocationPermission.whileInUse,
        LocationPermission.always,
      ]) {
        expect(
          await ensureLocationPermission(
            check: returns(p),
            request: () async {
              asked++;
              return p;
            },
          ),
          isTrue,
        );
      }
      expect(asked, 0);
    });

    test('denied 면 한 번 묻고 그 결과를 따른다', () async {
      expect(
        await ensureLocationPermission(
          check: returns(LocationPermission.denied),
          request: returns(LocationPermission.whileInUse),
        ),
        isTrue,
      );
      expect(
        await ensureLocationPermission(
          check: returns(LocationPermission.denied),
          request: returns(LocationPermission.deniedForever),
        ),
        isFalse,
      );
    });

    test('영구 거부 · 판단 불가면 묻지 않고 false', () async {
      for (final p in [
        LocationPermission.deniedForever,
        LocationPermission.unableToDetermine,
      ]) {
        expect(
          await ensureLocationPermission(
            check: returns(p),
            request: () => fail('묻지 않아야 한다'),
          ),
          isFalse,
        );
      }
    });

    testWidgets('권한 확인이 실패하면 false 를 돌려주고 오류를 보고한다', (tester) async {
      final allowed = await ensureLocationPermission(
        check: () async => throw Exception('activity 없음'),
      );
      expect(allowed, isFalse);
      expect(tester.takeException(), isA<Exception>());
    });

    testWidgets('권한 창 결과가 오지 않으면 시간 초과 뒤 false', (tester) async {
      bool? allowed;
      ensureLocationPermission(
        check: returns(LocationPermission.denied),
        request: () => Completer<LocationPermission>().future,
        timeout: const Duration(seconds: 60),
      ).then((v) => allowed = v);
      await tester.pump(const Duration(seconds: 59));
      expect(allowed, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(allowed, isFalse);
      expect(tester.takeException(), isA<TimeoutException>());
    });
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
