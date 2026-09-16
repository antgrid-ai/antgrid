import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds both response headers and body, and releases the underlying request
/// so repeated reconnect attempts cannot accumulate stalled sockets.
Future<http.Response> boundedHttpRequest(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Map<String, String>? bodyFields,
  String? body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final abort = Completer<void>();
  final request = http.AbortableRequest(
    method,
    uri,
    abortTrigger: abort.future,
  );
  if (headers != null) request.headers.addAll(headers);
  if (body != null) request.body = body;
  if (bodyFields != null) request.bodyFields = bodyFields;
  return client
      .send(request)
      .then(http.Response.fromStream)
      .timeout(
        timeout,
        onTimeout: () {
          abort.complete();
          throw TimeoutException('Account HTTP request timed out', timeout);
        },
      );
}
