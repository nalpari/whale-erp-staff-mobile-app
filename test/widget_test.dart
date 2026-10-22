import 'package:flutter_test/flutter_test.dart';
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
}
