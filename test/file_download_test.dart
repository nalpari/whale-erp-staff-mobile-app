// 실제 HttpClient 를 쓰는 테스트라 testWidgets 와 같은 파일에 두지 않는다.
// TestWidgetsFlutterBinding 이 초기화되면 모든 HTTP 요청이 400 으로 바뀐다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:staff/file_download.dart';

void main() {
  group('파일 받기', () {
    test('S3 서명 주소만 앱이 받는다', () {
      expect(
        isSignedDownload(Uri.parse(
            'https://bucket.s3.ap-northeast-2.amazonaws.com/a/b.pdf?X-Amz-Signature=abc&X-Amz-Expires=300')),
        isTrue,
      );
      expect(isSignedDownload(Uri.parse('https://bucket.s3.amazonaws.com/a.pdf')), isFalse);
      expect(
        isSignedDownload(Uri.parse('http://bucket.s3.amazonaws.com/a.pdf?X-Amz-Signature=abc')),
        isFalse,
      );
      expect(
        isSignedDownload(Uri.parse('https://evil-amazonaws.com/a.pdf?X-Amz-Signature=abc')),
        isFalse,
      );
      expect(isSignedDownload(Uri.parse('https://google.com/?X-Amz-Signature=abc')), isFalse);
    });

    test('Content-Disposition 에서 파일 이름 — filename* 우선, 위험한 글자는 지움', () {
      final url = Uri.parse('https://x.test/pay/1/pdf');
      expect(
        fileNameFrom("attachment; filename=\"a.pdf\"; filename*=UTF-8''%EA%B8%89%EC%97%AC.pdf", url, 'f'),
        '급여.pdf',
      );
      expect(fileNameFrom('attachment; filename="7월 급여.pdf"', url, 'f'), '7월 급여.pdf');
      expect(fileNameFrom('attachment; filename=plain.pdf', url, 'f'), 'plain.pdf');
      expect(fileNameFrom('attachment; filename="../../etc/x"', url, 'f'), '.._.._etc_x');
      expect(fileNameFrom(null, Uri.parse('https://s3.test/a/contract.pdf?x=1'), 'f'), 'contract.pdf');
      expect(fileNameFrom(null, url, '급여명세서.pdf'), '급여명세서.pdf');
      expect(fileNameFrom('attachment; filename=".."', url, 'f'), 'f');
    });

    group('downloadFile (로컬 서버)', () {
      late HttpServer server;
      late Directory dir;
      final seenCookies = <String?>[];

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('dl-test');
        seenCookies.clear();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          seenCookies.add(req.headers.value(HttpHeaders.cookieHeader));
          final res = req.response;
          switch (req.uri.path) {
            case '/pdf':
              res.headers.contentType = ContentType('application', 'pdf');
              // api 와 같은 형식(storage.service contentDisposition): filename*=UTF-8''<퍼센트 인코딩>
              res.headers.set('content-disposition', "attachment; filename*=UTF-8''${Uri.encodeComponent('명세서.pdf')}");
              res.add([37, 80, 68, 70]);
            case '/conflict':
              res.statusCode = 409;
              res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
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
          }
          await res.close();
        });
      });

      tearDown(() async {
        await server.close(force: true);
        await dir.delete(recursive: true);
      });

      Uri at(String path) => Uri.parse('http://${server.address.host}:${server.port}$path');

      test('파일이면 쿠키를 실어 받고 이름대로 저장한다', () async {
        final outcome = await downloadFile(at('/pdf'),
            directory: dir, fallbackName: 'f', cookie: 'access=1; refresh=2');
        expect(outcome, isA<DownloadedFile>());
        final file = outcome as DownloadedFile;
        expect(file.path, endsWith('/명세서.pdf'));
        expect(file.mimeType, 'application/pdf');
        expect(await File(file.path).readAsBytes(), [37, 80, 68, 70]);
        expect(seenCookies, ['access=1; refresh=2']);
      });

      test('리다이렉트를 따라가 받는다', () async {
        final outcome = await downloadFile(at('/redirect'), directory: dir, fallbackName: 'f');
        expect((outcome as DownloadedFile).path, endsWith('/명세서.pdf'));
      });

      test('실패 글자(text/plain)는 그대로 안내한다', () async {
        final outcome = await downloadFile(at('/conflict'), directory: dir, fallbackName: 'f');
        expect((outcome as DownloadMessage).message, '관리자가 명세서를 다시 검토하고 있습니다.');
      });

      test('화면(HTML)이 오면 웹뷰에서 연다', () async {
        expect(await downloadFile(at('/login'), directory: dir, fallbackName: 'f'),
            isA<OpenInWebView>());
      });

      test('그 밖의 실패 응답 · 연결 실패는 DownloadFailed', () async {
        expect(await downloadFile(at('/boom'), directory: dir, fallbackName: 'f'),
            isA<DownloadFailed>());
        expect(
          await downloadFile(Uri.parse('http://127.0.0.1:1/x'), directory: dir, fallbackName: 'f'),
          isA<DownloadFailed>(),
        );
      });
    });
  });
}
