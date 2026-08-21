import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/analytics/analytics_service.dart';

void main() {
  AnalyticsService build({
    required bool enabled,
    required List<http.Request> sink,
    int batchSize = 10,
  }) {
    final client = MockClient((req) async {
      sink.add(req);
      return http.Response('', 202);
    });
    return AnalyticsService(
      client: client,
      plausibleUrl: 'https://plausible.test',
      plausibleDomain: 'app.test',
      eventsApiUrl: 'https://api.test',
      installId: '11111111-1111-4111-8111-111111111111',
      platform: 'android',
      appVersion: '1.0.0',
      enabled: () => enabled,
      batchSize: batchSize,
    );
  }

  test('opted out: track sends nothing', () async {
    final sink = <http.Request>[];
    final svc = build(enabled: false, sink: sink);
    svc.track('session_opened');
    await svc.flush();
    expect(sink, isEmpty);
  });

  test('track posts to Plausible immediately with name + domain', () async {
    final sink = <http.Request>[];
    final svc = build(enabled: true, sink: sink);
    svc.track('session_opened', props: {'surface': 'mobile'});
    await Future<void>.delayed(Duration.zero);
    final plausible = sink.firstWhere((r) => r.url.host == 'plausible.test');
    final body = jsonDecode(plausible.body) as Map<String, dynamic>;
    expect(body['name'], 'session_opened');
    expect(body['domain'], 'app.test');
    expect(body['props']['surface'], 'mobile');
    // Zero-knowledge invariant: installId must never appear in the Plausible
    // body — Plausible is a third-party sink and must stay anonymous.
    const id = '11111111-1111-4111-8111-111111111111';
    expect(body.containsKey('installId'), isFalse);
    expect(body.containsKey('install_id'), isFalse);
    expect(jsonEncode(body).contains(id), isFalse);
  });

  test('first-party events batch and flush with installId', () async {
    final sink = <http.Request>[];
    final svc = build(enabled: true, sink: sink, batchSize: 2);
    svc.track('session_opened');
    svc.track('app_active'); // reaches batchSize -> auto-flush
    await Future<void>.delayed(Duration.zero);
    final ingest = sink.firstWhere((r) => r.url.host == 'api.test');
    final body = jsonDecode(ingest.body) as Map<String, dynamic>;
    expect((body['events'] as List).length, 2);
    const id = '11111111-1111-4111-8111-111111111111';
    // installId MUST be present in the first-party sink (proves asymmetry with
    // the Plausible test above which asserts its absence there).
    expect(body['events'][0]['installId'], id);
    expect(body['events'][0]['name'], 'session_opened');
  });

  test(
    'flush honors a runtime opt-out: queued events are dropped, not sent',
    () async {
      final sink = <http.Request>[];
      var enabled = true;
      final client = MockClient((req) async {
        sink.add(req);
        return http.Response('', 202);
      });
      final svc = AnalyticsService(
        client: client,
        plausibleUrl: 'https://plausible.test',
        plausibleDomain: 'app.test',
        eventsApiUrl: 'https://api.test',
        installId: '11111111-1111-4111-8111-111111111111',
        platform: 'android',
        appVersion: '1.0.0',
        enabled: () => enabled,
        batchSize: 100, // never auto-flushes — event stays queued
      );
      svc.track('session_opened');
      await Future<void>.delayed(Duration.zero);
      sink.clear();
      enabled = false; // user opts out before the queue is flushed
      await svc.flush();
      expect(
        sink.where((r) => r.url.host == 'api.test'),
        isEmpty,
        reason: 'opt-out must drop queued events, not transmit them on pause',
      );
    },
  );

  test(
    'prop string values longer than 120 chars are clamped before send',
    () async {
      final sink = <http.Request>[];
      final svc = build(enabled: true, sink: sink, batchSize: 1);
      svc.track('search_used', props: {'big': 'x' * 200});
      await Future<void>.delayed(Duration.zero);
      final ingest = sink.firstWhere((r) => r.url.host == 'api.test');
      final body = jsonDecode(ingest.body) as Map<String, dynamic>;
      final props = body['events'][0]['props'] as Map<String, dynamic>;
      expect((props['big'] as String).length, 120);
      // Plausible body shares the same clamped map.
      final plausible = sink.firstWhere((r) => r.url.host == 'plausible.test');
      final pbody = jsonDecode(plausible.body) as Map<String, dynamic>;
      expect((pbody['props']['big'] as String).length, 120);
    },
  );
}
