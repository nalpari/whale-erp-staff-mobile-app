import 'package:flutter_test/flutter_test.dart';
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
  });
}
