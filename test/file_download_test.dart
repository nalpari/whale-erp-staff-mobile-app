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

      test('다른 출처로 리다이렉트하면 쿠키를 떼고 넘긴다(로그인 쿠키가 새지 않는다)', () async {
        final outcome = await downloadFile(
          at('/cross'),
          directory: dir,
          fallbackName: 'f',
          cookie: 'access=1; refresh=2',
        );
        expect(outcome, isA<DownloadedFile>());
        expect(seenCookies, ['access=1; refresh=2']);
        expect(otherCookies, [null]);
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

      test('받을 때마다 지난 download-* 폴더를 지운다', () async {
        final first = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
        ) as DownloadedFile;
        final second = await downloadFile(
          at('/pdf'),
          directory: dir,
          fallbackName: 'f',
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
}
