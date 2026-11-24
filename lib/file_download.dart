import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 웹뷰 대신 앱이 받는 파일(계획 결정 10: 받은 파일은 공유 시트로 연다).
///
/// - 급여 PDF: `/pay/<id>/pdf` 가 같은 호스트에서 `application/pdf` attachment 로 내려준다. 로그인이 httpOnly 쿠키라
///   웹뷰 쿠키를 실어 받는다. 실패하면 이 라우트는 명세서 상세(`/pay/<id>?download=…`, 번호가 잘못되면 `/pay` 목록)로
///   돌려보내거나(옛 웹은 평문 text/plain) 로그인 화면으로 보낸다.
/// - 근로계약서: `/contracts/<id>/documents/<docId>` 가 S3 서명 주소(300초, attachment)로 302 이동한다. 다른 호스트라
///   예전에는 바깥 브라우저로 나갔다. 서명 주소 자체가 권한이라 쿠키 없이 받는다.

/// 받은 결과를 어떻게 다룰지.
sealed class DownloadOutcome {
  const DownloadOutcome();
}

/// 파일을 받았다. [path] 에 저장했다.
final class DownloadedFile extends DownloadOutcome {
  const DownloadedFile(this.path, this.mimeType);
  final String path;
  final String mimeType;
}

/// 서버가 사용자에게 보일 글자로 실패를 알렸다(급여 PDF 라우트의 text/plain). 그대로 안내한다.
final class DownloadMessage extends DownloadOutcome {
  const DownloadMessage(this.message);
  final String message;
}

/// 파일이 아니라 화면(200 HTML)이 왔다 — 접속이 끝나 로그인 화면으로 보낸 경우 등. 웹뷰에서 [url](리다이렉트를 따라간 뒤
/// HTML 이 온 최종 주소)을 열어 웹이 처리하게 한다. 처음 받으려던 주소를 다시 열면 같은 받기가 되풀이될 수 있다.
final class OpenInWebView extends DownloadOutcome {
  const OpenInWebView(this.url);
  final Uri url;
}

/// 연결 실패 · 시간 초과 · 저장 실패 · 실패 응답(HTML 오류 페이지 포함) 등. 일반 실패 안내를 띄운다.
final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.error, [this.stack]);
  final Object error;
  final StackTrace? stack;
}

const downloadFailedMessage = '파일을 받지 못했어요. 잠시 뒤 다시 시도해 주세요.';

/// 응답 헤더가 올 때까지의 제한. 급여 PDF 만드는 데 웹 라우트가 20초까지 기다린다. 그보다 조금 넉넉하게.
const downloadTimeout = Duration(seconds: 30);

/// 본문 전체를 받는 데 쓰는 상한. 무응답 제한([downloadIdleTimeout])은 조금씩 계속 오는 응답을 끊지 못해 따로 둔다.
/// 넘으면 연결은 downloadFile 이 끝날 때 끊기고 반쯤 받은 파일은 지운다.
const downloadBodyTimeout = Duration(seconds: 60);

/// 본문을 받는 동안 이만큼 아무 데이터도 오지 않으면 실패로 본다. 전체 시간으로 끊지 않아 큰 스캔본도 받을 수 있다.
const downloadIdleTimeout = Duration(seconds: 15);

/// 저장할 파일 이름의 최대 길이(UTF-8 바이트). 운영체제 한계 255바이트보다 여유 있게.
const _maxFileNameBytes = 200;

/// 앱이 직접 받아야 하는 S3 서명 주소인지. https 이고, S3(amazonaws.com) 호스트이며, 서명 값이 붙은 주소만.
/// 그 밖의 다른 호스트 주소는 지금처럼 바깥 앱 · 브라우저로 연다.
bool isSignedDownload(Uri uri) {
  if (uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  // S3 호스트만: s3.amazonaws.com, <버킷>.s3.amazonaws.com, (<버킷>.)s3.<리전>.amazonaws.com, s3-<리전> 옛 형식.
  // 다른 AWS 서비스(amazonaws.com 아래)는 계약서 주소로 보지 않는다.
  final isS3 = RegExp(r'(^|\.)s3([.-][a-z0-9-]+)?\.amazonaws\.com$')
      .hasMatch(host);
  // 서명 값이 비어 있으면 서명 주소가 아니다.
  final signed = uri.queryParameters.entries.any(
    (e) =>
        (e.key.toLowerCase() == 'x-amz-signature' ||
            e.key.toLowerCase() == 'signature') &&
        e.value.isNotEmpty,
  );
  return isS3 && signed;
}

/// 웹의 급여명세서 PDF 라우트(`/pay/<id>/pdf`)인지. 웹 주소와 같은 출처일 때만.
/// 이 라우트는 성공하면 첨부 PDF 를 주지만, 실패하면 명세서 상세로 돌려보내거나(옛 웹은 평문 오류 404 · 409 · 502) 로그인으로 보낸다. 그런 응답은
/// 웹뷰가 다운로드가 아니라 페이지로 열어 오류 글이 화면을 덮으므로, 웹뷰가 이동하기 전에 앱이 가로채 받는다.
/// 로그인 쿠키를 싣는 받기라 https 일 때만(WEB_URL 을 http 로 띄운 개발 환경에서도 평문으로 쿠키를 보내지 않는다).
bool isPayslipPdf(Uri uri, Uri base) =>
    uri.scheme == 'https' &&
    isSameOrigin(uri, base) &&
    RegExp(r'^/pay/[^/]+/pdf/?$').hasMatch(uri.path);

/// 웹이 급여명세서 PDF 받기에 실패해 돌려보낸 명세서 상세(`/pay/<id>?download=…`)인지. 웹 브랜치 `magmar`(2026-11-24)부터 실패는 평문
/// 대신 상세로 3xx(Next `redirect()`, 307) 하고 상세가 안내를 띄운다. 로그인 화면이 아니라 안내 화면이라, 같은 받기가 곧바로 또 화면을 받아도 「로그인 정보를
/// 확인하지 못함」(되풀이 막기)으로 보지 않고 그대로 연다. 같은 출처 · https 일 때만.
/// 잘못된 명세서 번호면 웹이 목록(`/pay`)으로 돌려보내므로 목록도 안내 화면으로 본다(로그인 화면이 아니라 되풀이할 일이 없다).
bool isPayslipFailurePage(Uri uri, Uri base) =>
    uri.scheme == 'https' &&
    isSameOrigin(uri, base) &&
    (RegExp(r'^/pay/?$').hasMatch(uri.path) ||
        (RegExp(r'^/pay/[^/]+/?$').hasMatch(uri.path) &&
            uri.queryParameters.containsKey('download')));

/// 받기가 화면(HTML)으로 끝나 그 화면을 웹뷰에 열 때의 기록. 같은 받기가 15초 안에 또 화면으로 끝나면 로그인 되풀이로 본다.
typedef OpenInWebViewRecord = ({Uri url, DateTime at});

/// 받기([url])가 화면([page])으로 끝났을 때 로그인 되풀이인지와 다음 기록을 정한다.
/// 받기 실패 안내 화면([isPayslipFailurePage])은 로그인 되풀이가 아니므로 15초 되풀이 막기에서 빼고 기록도 지운다
/// (그 뒤에 로그인 화면이 와도 첫 번째로 본다). 되풀이면 기록을 지운다.
({bool repeated, OpenInWebViewRecord? next}) openInWebViewGuard({
  required OpenInWebViewRecord? last,
  required Uri url,
  required Uri page,
  required Uri base,
  required DateTime now,
}) {
  final failurePage = isPayslipFailurePage(page, base);
  final repeated =
      !failurePage &&
      last != null &&
      last.url == url &&
      now.difference(last.at) < const Duration(seconds: 15);
  return (
    repeated: repeated,
    next: repeated || failurePage ? null : (url: url, at: now),
  );
}

/// `Content-Disposition` 에서 파일 이름을 꺼낸다. `filename*=UTF-8''...` 를 먼저 보고, 없으면 `filename="..."`.
/// 둘 다 없으면 주소의 마지막 경로, 그것도 쓸 수 없으면 [fallback]. 경로 구분자 같은 위험한 글자는 지운다.
String fileNameFrom(String? contentDisposition, Uri url, String fallback) {
  String? name;
  if (contentDisposition != null) {
    final extended = RegExp(
      r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)",
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (extended != null) {
      try {
        name = Uri.decodeComponent(extended.group(2)!.trim());
      } on ArgumentError {
        name = null;
      } on FormatException {
        // 퍼센트 인코딩은 맞지만 UTF-8 이 깨졌다. filename="..." 로 넘어간다.
        name = null;
      }
    }
    name ??= RegExp(
      r'filename\s*=\s*"([^"]*)"',
      caseSensitive: false,
    ).firstMatch(contentDisposition)?.group(1);
    name ??= RegExp(
      r'filename\s*=\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(contentDisposition)?.group(1)?.trim();
  }
  if (name == null || name.isEmpty) {
    final last = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
    name = last.contains('.') ? last : null;
  }
  final safe = (name ?? '')
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim();
  if (safe.isEmpty || safe == '.' || safe == '..') return fallback;
  return _limitBytes(safe, _maxFileNameBytes);
}

/// [name] 이 [maxBytes] 를 넘으면 확장자는 남기고 앞부분을 글자 단위로 자른다(한글 한 글자 = 3바이트).
String _limitBytes(String name, int maxBytes) {
  if (utf8.encode(name).length <= maxBytes) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 10 ? name.substring(dot) : '';
  final budget = maxBytes - utf8.encode(ext).length;
  final stem = StringBuffer();
  var used = 0;
  for (final rune in name.substring(0, name.length - ext.length).runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (used + size > budget) break;
    stem.write(char);
    used += size;
  }
  return '$stem$ext';
}

/// 받은 응답이 사용자에게 보일 실패 글자인지(급여 PDF 라우트: 4xx · 5xx 의 text/plain).
bool isMessageResponse(int status, String? contentType) =>
    status != 200 && (contentType ?? '').toLowerCase().startsWith('text/plain');

/// [url] 을 받아 [directory] 에 저장한다. [cookie] 가 있으면 Cookie 헤더로 싣는다(같은 호스트의 급여 PDF).
/// 리다이렉트는 따라간다. 출처가 바뀌는 리다이렉트에서는 Dart HttpClient 가 Cookie 헤더를 떼고 넘긴다(테스트로 고정).
/// 응답 헤더까지는 [timeout], 본문은 [idleTimeout] 동안 데이터가 없거나 전체가 [bodyTimeout] 을 넘으면 실패로 본다.
/// 결과는 늘 [DownloadOutcome] 하나이고 예외를 던지지 않는다.
Future<DownloadOutcome> downloadFile(
  Uri url, {
  required Directory directory,
  required String fallbackName,
  String? cookie,
  Future<String?> Function(Uri url)? cookieFor,
  String? userAgent,
  HttpClient Function()? clientFactory,
  Duration timeout = downloadTimeout,
  Duration idleTimeout = downloadIdleTimeout,
  Duration bodyTimeout = downloadBodyTimeout,
  Duration keepOldFor = keepDownloadsFor,
}) async {
  final client = (clientFactory ?? HttpClient.new)();
  try {
    await _removeOldDownloads(directory, keepFor: keepOldFor);
    return await _download(
      client,
      url,
      directory: directory,
      fallbackName: fallbackName,
      cookie: cookie,
      cookieFor: cookieFor,
      userAgent: userAgent,
      timeout: timeout,
      idleTimeout: idleTimeout,
      bodyTimeout: bodyTimeout,
    );
  } catch (e, s) {
    return DownloadFailed(e, s);
  } finally {
    client.close(force: true);
  }
}

/// 받은 파일을 지우기 전에 두는 시간. 공유 시트가 아직 파일을 읽고 있을 수 있어(받기 잠금은 공유 전에 풀린다),
/// 방금 받은 폴더는 다음 받기가 바로 지우지 않는다.
const keepDownloadsFor = Duration(minutes: 10);

/// 지난번에 받은 파일(`download-*` 폴더) 가운데 [keepFor] 보다 오래된 것을 지운다. 급여 PDF 가 임시 폴더에 쌓이지 않게.
/// 지우지 못하면 넘어간다. [directory] 는 앱 전체가 같이 쓰는 임시 폴더라, 우리가 만든 `download-*` 폴더만 지운다.
Future<void> _removeOldDownloads(
  Directory directory, {
  Duration keepFor = keepDownloadsFor,
}) async {
  try {
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(keepFor);
    await for (final entry in directory.list()) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entry is Directory &&
          name.startsWith('download-') &&
          (await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete(recursive: true).catchError((_) => entry);
      }
    }
  } catch (_) {
    // 정리에 실패해도 받기는 계속한다.
  }
}

/// 받을 파일의 상한(급여명세서 · 근로계약서는 수 MB 안쪽). 넘으면 받기를 멈추고 실패로 본다.
const maxFileBytes = 50 * 1024 * 1024;

/// 평문 오류 글의 상한. 넘으면 실패로 본다.
const maxMessageBytes = 64 * 1024;

/// [body] 를 [file] 에 쓴다. 조각마다 디스크 쓰기가 끝날 때까지 수신을 멈춰(일시 중지), 빠른 네트워크 · 느린 저장소에서도
/// 못 쓴 데이터가 메모리에 쌓이지 않는다. 쓰기 오류(저장 공간 부족 등)는 바로 받기 실패가 된다.
/// [limit] 안에 끝나지 않으면 구독을 끊고 TimeoutException.
Future<void> _writeWithin(
  Stream<List<int>> body,
  RandomAccessFile file,
  Duration limit,
) {
  final done = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  // 진행 중인 디스크 쓰기. 기한 · 오류로 끝낼 때 이 쓰기가 끝난 뒤에 알려야 부르는 쪽이 파일을 닫고 지울 수 있다.
  Future<void> pending = Future<void>.value();
  var finishing = false;
  void finish([Object? error, StackTrace? stack]) {
    if (finishing) return;
    finishing = true;
    if (error != null) {
      unawaited(subscription.cancel());
      pending.then<void>((_) {}, onError: (_) {}).whenComplete(() {
        if (!done.isCompleted) done.completeError(error, stack);
      });
    } else {
      done.complete();
    }
  }

  final timer = Timer(
    limit,
    () => finish(TimeoutException('본문을 기한 안에 다 받지 못함', limit)),
  );
  subscription = body.listen(
    (chunk) {
      subscription.pause();
      final write = file.writeFrom(chunk);
      pending = write;
      write.then(
        (_) {
          if (!finishing) subscription.resume();
        },
        onError: (Object e, StackTrace s) {
          timer.cancel();
          finish(e, s);
        },
      );
    },
    onError: (Object e, StackTrace s) {
      timer.cancel();
      finish(e, s);
    },
    onDone: () {
      timer.cancel();
      finish();
    },
    cancelOnError: true,
  );
  return done.future;
}

/// [body] 가 [limit] 바이트를 넘으면 오류로 끊는다.
Stream<List<int>> _capped(Stream<List<int>> body, int limit) {
  var received = 0;
  return body.map((chunk) {
    received += chunk.length;
    if (received > limit) {
      throw HttpException('응답이 너무 큼(${limit ~/ 1024}KB 초과)');
    }
    return chunk;
  });
}

/// 리다이렉트 응답이 준 쿠키 가운데 [url] 에 보낼 것(웹뷰와 같은 Path 규칙)을 이름 → 값으로. 만료된 쿠키는 빈 값(지움).
/// Domain 은 같은 출처 응답만 모으므로 따로 보지 않는다.
Map<String, String> cookiesFor(List<Cookie> cookies, Uri url) {
  final path = url.path.isEmpty ? '/' : url.path;
  final out = <String, String>{};
  for (final c in cookies) {
    final scope = c.path ?? '/';
    final inScope =
        path == scope ||
        (path.startsWith(scope) &&
            (scope.endsWith('/') || path[scope.length] == '/'));
    if (!inScope) continue;
    final expired =
        (c.maxAge != null && c.maxAge! <= 0) ||
        (c.expires != null && c.expires!.isBefore(DateTime.now()));
    out[c.name] = expired ? '' : c.value;
  }
  return out;
}

/// `Cookie` 헤더 값 [base](`a=1; b=2`)에 [overrides] 를 덮어쓴다. 값이 빈 것은 지운 쿠키로 보고 뺀다.
String mergeCookies(String? base, Map<String, String> overrides) {
  final cookies = <String, String>{};
  for (final part in (base ?? '').split(';')) {
    final at = part.indexOf('=');
    if (at <= 0) continue;
    cookies[part.substring(0, at).trim()] = part.substring(at + 1).trim();
  }
  cookies.addAll(overrides);
  return cookies.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => '${e.key}=${e.value}')
      .join('; ');
}

/// 파일 받기에서 따라갈 리다이렉트 수. HttpClient 기본값과 같다.
const maxDownloadRedirects = 5;

/// 두 주소가 같은 출처(스킴 · 호스트 · 포트)인지. [Uri.port] 는 생략된 포트를 기본 포트로 본다.
bool isSameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.host == b.host && a.port == b.port;

/// 오류 기록용 글. 주소의 쿼리(S3 서명 값 등)를 지운다. 서명 주소가 남으면 만료 전까지 파일을 받을 수 있다.
String redactUrls(String text) => text.replaceAllMapped(
  RegExp(r'(https?://[^\s?#]+)[?#][^\s]*'),
  (m) => '${m[1]}?…',
);

Future<DownloadOutcome> _download(
  HttpClient client,
  Uri url, {
  required Directory directory,
  required String fallbackName,
  String? cookie,
  Future<String?> Function(Uri url)? cookieFor,
  String? userAgent,
  required Duration timeout,
  required Duration idleTimeout,
  required Duration bodyTimeout,
}) async {
  // 연결부터 응답 헤더(리다이렉트 포함)까지를 한 번의 [timeout] 으로 묶는다.
  // 리다이렉트는 직접 따라간다. HttpClient 의 자동 리다이렉트는 호스트가 바뀔 때만 쿠키를 떼서, 같은 호스트의
  // 다른 포트 · http 로 가면 로그인 쿠키가 따라간다. 쿠키는 처음 주소와 같은 출처(스킴 · 호스트 · 포트)에만 싣는다.
  var finalUrl = url;
  // 같은 출처 리다이렉트 응답이 Set-Cookie 로 준 쿠키(로그인 갱신 등). 다음 요청에서 웹뷰 쿠키보다 앞선다.
  final refreshed = <Cookie>[];
  final response = await () async {
    for (var redirects = 0; ; redirects++) {
      final request = await client.getUrl(finalUrl);
      request.followRedirects = false;
      if (isSameOrigin(finalUrl, url)) {
        // 쿠키는 이동할 때마다 그 주소에 맞는 것(Path 등)을 다시 고른다. [cookieFor] 가 없으면 처음 쿠키를 쓴다.
        final value = mergeCookies(
          cookieFor != null ? await cookieFor(finalUrl) : cookie,
          cookiesFor(refreshed, finalUrl),
        );
        if (value.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, value);
        }
      }
      if (userAgent != null) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (!response.isRedirect || location == null) return response;
      await response.drain<void>();
      if (isSameOrigin(finalUrl, url)) {
        for (final c in response.cookies) {
          // 같은 이름 · 경로의 앞 갱신은 새 것으로 바꾼다.
          refreshed.removeWhere(
            (o) => o.name == c.name && (o.path ?? '/') == (c.path ?? '/'),
          );
          refreshed.add(c);
        }
      }
      if (redirects >= maxDownloadRedirects) {
        throw const HttpException('파일 받기 리다이렉트가 너무 많음');
      }
      final next = finalUrl.resolve(location);
      // 이동은 처음 주소와 같은 출처(로그인 화면 등)나 S3 서명 주소로만 따라간다. 그 밖(사설망 · 다른 호스트)은 받지 않는다.
      if (!isSameOrigin(next, url) && !isSignedDownload(next)) {
        throw const HttpException('허용하지 않는 곳으로 리다이렉트됨');
      }
      finalUrl = next;
    }
  }().timeout(timeout);
  final status = response.statusCode;
  final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
  final disposition = response.headers.value('content-disposition');
  // 본문은 전체 시간이 아니라 데이터가 끊긴 시간으로 끊는다.
  final body = response.timeout(idleTimeout);

  if (isMessageResponse(status, contentType)) {
    final text =
        (await utf8
                .decodeStream(_capped(body, maxMessageBytes))
                .timeout(bodyTimeout))
            .trim();
    return DownloadMessage(text.isEmpty ? downloadFailedMessage : text);
  }
  final isHtml = (contentType ?? '').toLowerCase().startsWith('text/html');
  // 본문이 필요 없는 응답은 기다리지 않는다. 연결은 downloadFile 이 끝날 때 client.close(force: true) 로 끊긴다.
  // (본문을 다 읽으려 하면 조금씩 계속 오는 응답에 무응답 제한이 걸리지 않아 끝나지 않는다.)
  if (isHtml && status == 200) {
    return OpenInWebView(finalUrl);
  }
  if (status != 200) {
    // 502 · 504 같은 HTML 오류 페이지도 여기로 온다. 웹뷰로 넘기면 오류 페이지가 화면을 덮는다.
    // 주소는 담지 않는다. S3 서명 주소가 오류 기록에 남으면 만료 전까지 계약서를 받을 수 있다.
    return DownloadFailed(HttpException('응답 $status'));
  }

  final name = fileNameFrom(disposition, finalUrl, fallbackName);
  // 받을 때마다 새 폴더에 둔다. 같은 이름의 지난 파일을 덮어쓰다 공유 중인 파일이 바뀌지 않게.
  final folder = await directory.createTemp('download-');
  final file = File('${folder.path}/$name');
  final raf = await file.open(mode: FileMode.write);
  try {
    await _writeWithin(_capped(body, maxFileBytes), raf, bodyTimeout);
    await raf.close();
  } catch (e) {
    await raf.close().then<void>((_) {}, onError: (_) {});
    // 반쯤 받은 파일은 남기지 않는다.
    await folder.delete(recursive: true).catchError((_) => folder);
    rethrow;
  }
  return DownloadedFile(
    file.path,
    (contentType ?? 'application/octet-stream').split(';').first.trim(),
  );
}
