// 실제 HttpClient 를 쓰는 테스트라 testWidgets 와 같은 파일에 두지 않는다.
// TestWidgetsFlutterBinding 이 초기화되면 모든 HTTP 요청이 400 으로 바뀐다.
import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:staff/file_download.dart';

void main() {
  group('파일 받기', () {
    test('S3 서명 주소만 앱이 받는다', () {
      expect(
        isSignedDownload(
          Uri.parse(
            'https://bucket.s3.ap-northeast-2.amazonaws.com/a/b.pdf?X-Amz-Signature=abc&X-Amz-Expires=300',
          ),
        ),
        isTrue,
      );
      expect(
        isSignedDownload(Uri.parse('https://bucket.s3.amazonaws.com/a.pdf')),
        isFalse,
      );
      expect(
        isSignedDownload(
          Uri.parse('http://bucket.s3.amazonaws.com/a.pdf?X-Amz-Signature=abc'),
        ),
        isFalse,
      );
      expect(
        isSignedDownload(
          Uri.parse('https://evil-amazonaws.com/a.pdf?X-Amz-Signature=abc'),
        ),
        isFalse,
      );
      expect(
        isSignedDownload(Uri.parse('https://google.com/?X-Amz-Signature=abc')),
        isFalse,
      );
      for (final fake in [
        'https://amazonaws.com.evil.com/a.pdf?X-Amz-Signature=abc',
        'https://evil.amazonaws.com.attacker/a.pdf?X-Amz-Signature=abc',
        'https://s3.amazonaws.com@evil.com/a.pdf?X-Amz-Signature=abc',
      ]) {
        expect(isSignedDownload(Uri.parse(fake)), isFalse, reason: fake);
      }
      expect(
        isSignedDownload(
          Uri.parse('https://bucket.s3.amazonaws.com/a.pdf?signature=abc'),
        ),
        isTrue,
      );
    });

    test('Content-Disposition 에서 파일 이름 — filename* 우선, 위험한 글자는 지움', () {
      final url = Uri.parse('https://x.test/pay/1/pdf');
      expect(
        fileNameFrom(
          "attachment; filename=\"a.pdf\"; filename*=UTF-8''%EA%B8%89%EC%97%AC.pdf",
          url,
          'f',
        ),
        '급여.pdf',
      );
      expect(
        fileNameFrom('attachment; filename="7월 급여.pdf"', url, 'f'),
        '7월 급여.pdf',
      );
      expect(
        fileNameFrom('attachment; filename=plain.pdf', url, 'f'),
        'plain.pdf',
      );
      expect(
        fileNameFrom('attachment; filename="../../etc/x"', url, 'f'),
        '.._.._etc_x',
      );
      expect(
        fileNameFrom(
          null,
          Uri.parse('https://s3.test/a/contract.pdf?x=1'),
          'f',
        ),
        'contract.pdf',
      );
      expect(fileNameFrom(null, url, '급여명세서.pdf'), '급여명세서.pdf');
      expect(fileNameFrom('attachment; filename=".."', url, 'f'), 'f');
      // api 형식 그대로의 경로 조작도 파일 이름 안에 갇힌다.
      expect(
        fileNameFrom("attachment; filename*=UTF-8''..%2F..%2Fx.pdf", url, 'f'),
        '.._.._x.pdf',
      );
      expect(
        fileNameFrom(r'attachment; filename="..\..\x"', url, 'f'),
        '.._.._x',
      );
    });

    test('filename* 의 UTF-8 이 깨져 있으면 filename="..." 로 넘어간다', () {
      final url = Uri.parse('https://x.test/pay/1/pdf');
      expect(
        fileNameFrom(
          "attachment; filename=\"a.pdf\"; filename*=UTF-8''%FF.pdf",
          url,
          'f',
        ),
        'a.pdf',
      );
    });

    test('긴 파일 이름은 확장자를 남기고 200바이트 안으로 자른다', () {
      final url = Uri.parse('https://x.test/c');
      final name = fileNameFrom(
        'attachment; filename="${'가' * 100}.pdf"',
        url,
        'f',
      );
      expect(name, endsWith('.pdf'));
      expect(utf8.encode(name).length, lessThanOrEqualTo(200));
      expect(name.startsWith('가가가'), isTrue);
    });

    group('downloadFile (로컬 서버)', () {
      late HttpServer server;
      late HttpServer other;
      late Directory dir;
      final seenCookies = <String?>[];
      final otherCookies = <String?>[];

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('dl-test');
        seenCookies.clear();
        otherCookies.clear();
        // 다른 출처(호스트 이름 · 포트가 다름). 리다이렉트로 쿠키가 넘어가는지 본다.
        other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        other.listen((req) async {
          otherCookies.add(req.headers.value(HttpHeaders.cookieHeader));
          req.response.headers.contentType = ContentType('application', 'pdf');
          req.response.add([1, 2, 3]);
          await req.response.close();
        });
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          seenCookies.add(req.headers.value(HttpHeaders.cookieHeader));
          final res = req.response;
          switch (req.uri.path) {
            case '/pdf':
              res.headers.contentType = ContentType('application', 'pdf');
              // api 와 같은 형식(storage.service contentDisposition): filename*=UTF-8''<퍼센트 인코딩>
              res.headers.set(
                'content-disposition',
                "attachment; filename*=UTF-8''${Uri.encodeComponent('명세서.pdf')}",
              );
              res.add([37, 80, 68, 70]);
            case '/conflict':
              res.statusCode = 409;
              res.headers.contentType = ContentType(
                'text',
                'plain',
                charset: 'utf-8',
              );
              res.write('관리자가 명세서를 다시 검토하고 있습니다.');
            case '/login':
              res.headers.contentType = ContentType.html;
              res.write('<html>login</html>');
            case '/redirect':
              res.redirect(Uri.parse('/pdf'));
              return;
            case '/boom':
              res.statusCode = 500;
              res.headers.contentType = ContentType.json;
              res.write('{}');
            case '/bad-gateway':
              res.statusCode = 502;
              res.headers.contentType = ContentType.html;
              res.write('<html>502 Bad Gateway</html>');
            case '/to-login':
              res.redirect(Uri.parse('/login?next=/pay/1'));
              return;
            case '/a/r1':
              res.redirect(Uri.parse('b/r2')); // → /a/b/r2
              return;
            case '/a/b/r2':
              res.redirect(Uri.parse('../login')); // → /a/login
              return;
            case '/a/login':
              res.headers.contentType = ContentType.html;
              res.write('<html>login</html>');
            case '/cross':
              res.redirect(
                Uri.parse('http://localhost:${other.port}/file.pdf'),
              );
              return;
            case '/same-host':
              // 호스트는 같고 포트만 다르다. HttpClient 자동 리다이렉트는 이때 쿠키를 떼지 않는다.
              res.redirect(
                Uri.parse(
                  'http://${server.address.host}:${other.port}/file.pdf',
                ),
              );
              return;
            case '/refresh':
              // 로그인을 갱신하며 PDF 로 돌려보낸다.
              res.cookies.add(Cookie('access', 'new'));
              res.redirect(Uri.parse('/pdf'));
              return;
            case '/loop':
              res.redirect(Uri.parse('/loop'));
              return;
            case '/stall-headers':
              return; // 답하지 않는다.
            case '/stall-body':
              res.headers.contentType = ContentType('application', 'pdf');
              res.add([1]);
              await res.flush();
              return; // 본문을 더 보내지 않는다.
          }
          await res.close();
        });
      });

      tearDown(() async {
        await other.close(force: true);
        await server.close(force: true);
        await dir.delete(recursive: true);
      });

      Uri at(String path) =>
          Uri.parse('http://${server.address.host}:${server.port}$path');

      test('파일이면 쿠키를 실어 받고 이름대로 저장한다', () async {
        final outcome = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1; refresh=2',
        );
        expect(outcome, isA<DownloadedFile>());
        final file = outcome as DownloadedFile;
        expect(file.path, endsWith('/명세서.pdf'));
        expect(file.mimeType, 'application/pdf');
        expect(await File(file.path).readAsBytes(), [37, 80, 68, 70]);
        expect(seenCookies, ['access=1; refresh=2']);
      });

      test('같은 출처 리다이렉트는 쿠키를 유지하며 따라가 받는다', () async {
        final outcome = await downloadFile(
          at('/redirect'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1',
        );
        expect((outcome as DownloadedFile).path, endsWith('/명세서.pdf'));
        expect(seenCookies, ['access=1', 'access=1']);
      });

      test('다른 호스트로 리다이렉트하면 따라가지 않고 실패한다(로그인 쿠키도 안 간다)', () async {
        final outcome = await downloadFile(
          at('/cross'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1; refresh=2',
        );
        expect(outcome, isA<DownloadFailed>());
        expect(seenCookies, ['access=1; refresh=2']);
        expect(otherCookies, isEmpty);
      });

      test('같은 호스트의 다른 포트로 리다이렉트해도 다른 출처라 따라가지 않는다', () async {
        final outcome = await downloadFile(
          at('/same-host'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1; refresh=2',
        );
        expect(outcome, isA<DownloadFailed>());
        expect(seenCookies, ['access=1; refresh=2']);
        expect(otherCookies, isEmpty);
      });

      test('본문이 조금씩 계속 와도 전체 기한을 넘으면 멈추고 반쯤 받은 파일을 지운다', () async {
        final drip = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => drip.close(force: true));
        drip.listen((req) async {
          req.response.headers.contentType = ContentType('application', 'pdf');
          try {
            for (var i = 0; i < 100; i++) {
              req.response.add([1]);
              await req.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            await req.response.close();
          } catch (_) {}
        });
        final outcome = await downloadFile(
          Uri.parse('http://${drip.address.host}:${drip.port}/drip.pdf'),
          directory: dir,
          fallbackName: 'f',
          idleTimeout: const Duration(seconds: 1),
          bodyTimeout: const Duration(milliseconds: 200),
        );
        expect(outcome, isA<DownloadFailed>());
        expect(
          dir.listSync().where((e) => e.path.contains('download-')),
          isEmpty,
        );
      });

      test('받을 파일이 상한을 넘으면 멈추고 반쯤 받은 파일을 남기지 않는다', () async {
        final big = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => big.close(force: true));
        big.listen((req) async {
          req.response.headers.contentType = ContentType('application', 'pdf');
          final chunk = List.filled(1024 * 1024, 0);
          for (var i = 0; i <= maxFileBytes ~/ chunk.length; i++) {
            req.response.add(chunk);
          }
          await req.response.close().catchError((_) {});
        });
        final outcome = await downloadFile(
          Uri.parse('http://${big.address.host}:${big.port}/big.pdf'),
          directory: dir,
          fallbackName: 'f',
        );
        expect(outcome, isA<DownloadFailed>());
        expect(
          dir.listSync().where((e) => e.path.contains('download-')),
          isEmpty,
        );
      });

      test('리다이렉트 응답이 준 쿠키(로그인 갱신)를 다음 요청에 싣는다', () async {
        final outcome = await downloadFile(
          at('/refresh'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=old; keep=1',
        );
        expect(outcome, isA<DownloadedFile>());
        expect(seenCookies, ['access=old; keep=1', 'access=new; keep=1']);
      });

      test('리다이렉트마다 그 주소에 맞는 쿠키를 다시 고른다', () async {
        final asked = <String>[];
        final outcome = await downloadFile(
          at('/redirect'),
          directory: dir,
          fallbackName: 'f',
          cookieFor: (u) async {
            asked.add(u.path);
            return u.path == '/pdf' ? 'pdf=1' : 'first=1';
          },
        );
        expect(outcome, isA<DownloadedFile>());
        expect(asked, ['/redirect', '/pdf']);
        expect(seenCookies, ['first=1', 'pdf=1']);
      });

      test('같은 출처 안의 리다이렉트는 쿠키를 그대로 싣는다', () async {
        final outcome = await downloadFile(
          at('/redirect'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1',
        );
        expect(outcome, isA<DownloadedFile>());
        expect(seenCookies, ['access=1', 'access=1']);
      });

      test('리다이렉트가 끝없이 이어지면 실패로 끝낸다', () async {
        final outcome = await downloadFile(
          at('/loop'),
          directory: dir,
          fallbackName: 'f',
        );
        expect(outcome, isA<DownloadFailed>());
        expect(seenCookies.length, maxDownloadRedirects + 1);
      });

      test('지난 받기를 지울 때 download-* 폴더만 지우고 다른 것은 남긴다', () async {
        final keepDir = Directory('${dir.path}/other-dir')..createSync();
        final keepFile = File('${keepDir.path}/keep.txt')
          ..writeAsStringSync('x');
        final lookalike = File('${dir.path}/download-note.txt')
          ..writeAsStringSync('x');
        await downloadFile(at('/pdf'), directory: dir, fallbackName: 'f');
        await downloadFile(at('/pdf'), directory: dir, fallbackName: 'f');
        expect(keepFile.existsSync(), isTrue);
        expect(lookalike.existsSync(), isTrue);
      });

      test('리다이렉트가 여러 번이면 직전 주소를 기준으로 상대 주소를 푼다', () async {
        final outcome = await downloadFile(
          at('/a/r1'),
          directory: dir,
          fallbackName: 'f',
        );
        expect((outcome as OpenInWebView).url.path, '/a/login');
      });

      test('방금 받은 폴더는 공유 시트가 읽고 있을 수 있어 다음 받기가 지우지 않는다', () async {
        final first = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
        ) as DownloadedFile;
        await downloadFile(at('/pdf'), directory: dir, fallbackName: 'f');
        expect(File(first.path).existsSync(), isTrue);
      });

      test('받을 때마다 오래된 download-* 폴더를 지운다', () async {
        final first = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
        ) as DownloadedFile;
        final second = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
          keepOldFor: Duration.zero,
        ) as DownloadedFile;
        expect(File(first.path).existsSync(), isFalse);
        expect(File(second.path).existsSync(), isTrue);
        expect(File(second.path).parent.parent.path, dir.path);
      });

      test('실패 글자(text/plain)는 그대로 안내한다', () async {
        final outcome = await downloadFile(
          at('/conflict'),
          directory: dir,
          fallbackName: 'f',
        );
        expect((outcome as DownloadMessage).message, '관리자가 명세서를 다시 검토하고 있습니다.');
      });

      test('화면(200 HTML)이 오면 HTML 이 온 최종 주소를 웹뷰에서 연다', () async {
        final outcome = await downloadFile(
          at('/to-login'),
          directory: dir,
          fallbackName: 'f',
        );
        expect(outcome, isA<OpenInWebView>());
        expect((outcome as OpenInWebView).url.path, '/login');
        expect(outcome.url.query, 'next=/pay/1');
      });

      test('HTML 오류 페이지(502)는 웹뷰로 넘기지 않고 DownloadFailed', () async {
        final outcome = await downloadFile(
          at('/bad-gateway'),
          directory: dir,
          fallbackName: 'f',
        );
        expect(
          outcome,
          isA<DownloadFailed>().having(
            (o) => o.error,
            'error',
            isA<HttpException>(),
          ),
        );
      });

      test('그 밖의 실패 응답 · 연결 실패는 원인을 담은 DownloadFailed', () async {
        expect(
          await downloadFile(at('/boom'), directory: dir, fallbackName: 'f'),
          isA<DownloadFailed>().having(
            (o) => o.error,
            'error',
            isA<HttpException>(),
          ),
        );
        expect(
          await downloadFile(
            Uri.parse('http://127.0.0.1:1/x'),
            directory: dir,
            fallbackName: 'f',
          ),
          isA<DownloadFailed>().having(
            (o) => o.error,
            'error',
            isA<SocketException>(),
          ),
        );
      });

      test('응답 헤더가 제한 시간 안에 오지 않으면 TimeoutException 으로 실패', () async {
        expect(
          await downloadFile(
            at('/stall-headers'),
            directory: dir,
            fallbackName: 'f',
            timeout: const Duration(milliseconds: 200),
          ),
          isA<DownloadFailed>().having(
            (o) => o.error,
            'error',
            isA<TimeoutException>(),
          ),
        );
      });

      test('본문이 끊긴 채 오지 않으면 TimeoutException 으로 실패', () async {
        expect(
          await downloadFile(
            at('/stall-body'),
            directory: dir,
            fallbackName: 'f',
            idleTimeout: const Duration(milliseconds: 200),
          ),
          isA<DownloadFailed>().having(
            (o) => o.error,
            'error',
            isA<TimeoutException>(),
          ),
        );
      });
    });
  });

  test('같은 출처는 스킴 · 호스트 · 포트가 모두 같을 때만', () {
    final base = Uri.parse('https://staff-dev.whaleerp.co.kr/pay/1');
    expect(
      isSameOrigin(Uri.parse('https://staff-dev.whaleerp.co.kr:443/x'), base),
      isTrue,
    );
    expect(
      isSameOrigin(Uri.parse('https://staff-dev.whaleerp.co.kr:8443/x'), base),
      isFalse,
    );
    expect(
      isSameOrigin(Uri.parse('http://staff-dev.whaleerp.co.kr/x'), base),
      isFalse,
    );
    expect(
      isSameOrigin(Uri.parse('https://a.staff-dev.whaleerp.co.kr/x'), base),
      isFalse,
    );
  });

  test('오류 기록에서 주소의 쿼리(서명 값)를 지운다', () {
    expect(
      redactUrls(
        'HttpException: 응답 503, uri = https://b.s3.ap-northeast-2.amazonaws.com/c.pdf?X-Amz-Signature=abc&X-Amz-Credential=k 뒤',
      ),
      'HttpException: 응답 503, uri = https://b.s3.ap-northeast-2.amazonaws.com/c.pdf?… 뒤',
    );
    expect(redactUrls('쿼리 없는 https://a.b/c'), '쿼리 없는 https://a.b/c');
  });

  test('급여명세서 PDF 라우트는 웹 주소와 같은 출처의 /pay/<id>/pdf 만', () {
    final base = Uri.parse('https://staff-dev.whaleerp.co.kr');
    expect(
      isPayslipPdf(
        Uri.parse('https://staff-dev.whaleerp.co.kr/pay/12/pdf'),
        base,
      ),
      isTrue,
    );
    expect(
      isPayslipPdf(Uri.parse('https://staff-dev.whaleerp.co.kr/pay/12'), base),
      isFalse,
    );
    expect(
      isPayslipPdf(
        Uri.parse('https://staff-dev.whaleerp.co.kr/pay/12/pdf/x'),
        base,
      ),
      isFalse,
    );
    expect(
      isPayslipPdf(Uri.parse('https://evil.example.com/pay/12/pdf'), base),
      isFalse,
    );
    expect(
      isPayslipPdf(
        Uri.parse('http://staff-dev.whaleerp.co.kr/pay/12/pdf'),
        base,
      ),
      isFalse,
    );
    // WEB_URL 이 http 여도 로그인 쿠키를 싣는 가로채기는 하지 않는다.
    expect(
      isPayslipPdf(
        Uri.parse('http://localhost:3000/pay/12/pdf'),
        Uri.parse('http://localhost:3000'),
      ),
      isFalse,
    );
  });

  test('S3 호스트만 계약서 서명 주소로 본다', () {
    bool signed(String host) =>
        isSignedDownload(Uri.parse('https://$host/a.pdf?X-Amz-Signature=x'));
    expect(signed('s3.amazonaws.com'), isTrue);
    expect(signed('bucket.s3.amazonaws.com'), isTrue);
    expect(signed('bucket.s3.ap-northeast-2.amazonaws.com'), isTrue);
    expect(signed('s3.ap-northeast-2.amazonaws.com'), isTrue);
    expect(signed('bucket.s3-ap-northeast-2.amazonaws.com'), isTrue);
    expect(signed('abc.execute-api.ap-northeast-2.amazonaws.com'), isFalse);
    expect(signed('lambda-url.ap-northeast-2.on.aws'), isFalse);
    expect(signed('evil-s3.amazonaws.com.example.com'), isFalse);
    expect(
      isSignedDownload(
        Uri.parse('https://bucket.s3.amazonaws.com/a.pdf?X-Amz-Signature='),
      ),
      isFalse,
    );
  });

  test('쿠키 덮어쓰기: 새 값은 바꾸고 빈 값(만료)은 뺀다', () {
    expect(mergeCookies('a=1; b=2', {'b': '3'}), 'a=1; b=3');
    expect(mergeCookies('a=1; b=2', {'a': ''}), 'b=2');
    expect(mergeCookies(null, {'c': '4'}), 'c=4');
    expect(mergeCookies('a=x=y', {}), 'a=x=y');
  });

  test('리다이렉트로 받은 쿠키는 Path 가 맞는 주소에만 보낸다', () {
    final pay = Cookie('pay', '1')..path = '/pay';
    final all = Cookie('access', 'new')..path = '/';
    final gone = Cookie('old', 'x')..maxAge = 0;
    final cookies = [pay, all, gone];
    expect(cookiesFor(cookies, Uri.parse('https://a.b/pay/1/pdf')), {
      'pay': '1',
      'access': 'new',
      'old': '',
    });
    expect(cookiesFor(cookies, Uri.parse('https://a.b/login')), {
      'access': 'new',
      'old': '',
    });
    expect(cookiesFor(cookies, Uri.parse('https://a.b/payroll')), {
      'access': 'new',
      'old': '',
    });
  });
}
