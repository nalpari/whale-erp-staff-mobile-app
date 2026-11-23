import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 웹뷰 대신 앱이 받는 파일(계획 결정 10: 받은 파일은 공유 시트로 연다).
///
/// - 급여 PDF: `/pay/<id>/pdf` 가 같은 호스트에서 `application/pdf` attachment 로 내려준다. 로그인이 httpOnly 쿠키라
///   웹뷰 쿠키를 실어 받는다. 실패하면 이 라우트는 평문 글자(text/plain)를 돌려주거나 로그인 화면으로 보낸다.
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

/// 파일이 아니라 화면(HTML)이 왔다 — 접속이 끝나 로그인 화면으로 보낸 경우 등. 웹뷰에서 그 주소를 열어 웹이 처리하게 한다.
final class OpenInWebView extends DownloadOutcome {
  const OpenInWebView();
}

/// 연결 실패 · 시간 초과 · 저장 실패 등. 일반 실패 안내를 띄운다.
final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.error);
  final Object error;
}

const downloadFailedMessage = '파일을 받지 못했어요. 잠시 뒤 다시 시도해 주세요.';

/// 급여 PDF 만드는 데 웹 라우트가 20초까지 기다린다. 그보다 조금 넉넉하게.
const downloadTimeout = Duration(seconds: 30);

/// 앱이 직접 받아야 하는 S3 서명 주소인지. https 이고, S3(amazonaws.com) 호스트이며, 서명 값이 붙은 주소만.
/// 그 밖의 다른 호스트 주소는 지금처럼 바깥 앱 · 브라우저로 연다.
bool isSignedDownload(Uri uri) {
  if (uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  final isS3 = host == 's3.amazonaws.com' || host.endsWith('.amazonaws.com');
  final params = uri.queryParameters.keys.map((key) => key.toLowerCase());
  return isS3 &&
      (params.contains('x-amz-signature') || params.contains('signature'));
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
  final safe = (name ?? '').replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return safe.isEmpty || safe == '.' || safe == '..' ? fallback : safe;
}

/// 받은 응답이 사용자에게 보일 실패 글자인지(급여 PDF 라우트: 4xx · 5xx 의 text/plain).
bool isMessageResponse(int status, String? contentType) =>
    status != 200 && (contentType ?? '').toLowerCase().startsWith('text/plain');

/// [url] 을 받아 [directory] 에 저장한다. [cookie] 가 있으면 Cookie 헤더로 싣는다(같은 호스트의 급여 PDF).
/// 리다이렉트는 따라간다. 결과는 늘 [DownloadOutcome] 하나이고 예외를 던지지 않는다.
Future<DownloadOutcome> downloadFile(
  Uri url, {
  required Directory directory,
  required String fallbackName,
  String? cookie,
  String? userAgent,
  HttpClient Function()? clientFactory,
  Duration timeout = downloadTimeout,
}) async {
  final client = (clientFactory ?? HttpClient.new)();
  try {
    return await _download(
      client,
      url,
      directory: directory,
      fallbackName: fallbackName,
      cookie: cookie,
      userAgent: userAgent,
    ).timeout(timeout);
  } catch (e) {
    return DownloadFailed(e);
  } finally {
    client.close(force: true);
  }
}

Future<DownloadOutcome> _download(
  HttpClient client,
  Uri url, {
  required Directory directory,
  required String fallbackName,
  String? cookie,
  String? userAgent,
}) async {
  final request = await client.getUrl(url);
  if (cookie != null && cookie.isNotEmpty) {
    request.headers.set(HttpHeaders.cookieHeader, cookie);
  }
  if (userAgent != null) {
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
  }
  final response = await request.close();
  final status = response.statusCode;
  final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
  final disposition = response.headers.value('content-disposition');

  if (isMessageResponse(status, contentType)) {
    final text = (await utf8.decodeStream(response)).trim();
    return DownloadMessage(text.isEmpty ? downloadFailedMessage : text);
  }
  if ((contentType ?? '').toLowerCase().startsWith('text/html')) {
    await response.drain<void>();
    return const OpenInWebView();
  }
  if (status != 200) {
    await response.drain<void>();
    return DownloadFailed(HttpException('응답 $status', uri: url));
  }

  final finalUrl = response.redirects.isEmpty
      ? url
      : url.resolveUri(response.redirects.last.location);
  final name = fileNameFrom(disposition, finalUrl, fallbackName);
  // 받을 때마다 새 폴더에 둔다. 같은 이름의 지난 파일을 덮어쓰다 공유 중인 파일이 바뀌지 않게.
  final folder = await directory.createTemp('download-');
  final file = File('${folder.path}/$name');
  final sink = file.openWrite();
  try {
    await response.pipe(sink);
  } catch (e) {
    await sink.close().catchError((_) {});
    rethrow;
  }
  return DownloadedFile(
    file.path,
    (contentType ?? 'application/octet-stream').split(';').first.trim(),
  );
}
