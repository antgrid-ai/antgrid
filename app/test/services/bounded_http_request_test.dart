import 'dart:async';

import 'package:antgrid/services/bounded_http_request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

void main() {
  for (final stallBody in [false, true]) {
    test('timeout aborts stalled ${stallBody ? 'body' : 'headers'}', () async {
      final aborted = Completer<void>();
      final body = StreamController<List<int>>();
      final headers = Completer<http.StreamedResponse>();
      final client = _Client((request) {
        (request as http.Abortable).abortTrigger!.then(
          (_) => aborted.complete(),
        );
        return stallBody
            ? Future.value(http.StreamedResponse(body.stream, 200))
            : headers.future;
      });
      await expectLater(
        boundedHttpRequest(
          client,
          'GET',
          Uri.parse('https://api.antgrid.test'),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future;
      if (!stallBody) {
        headers.complete(http.StreamedResponse(const Stream.empty(), 200));
      }
      if (stallBody) await body.close();
    });
  }
}
