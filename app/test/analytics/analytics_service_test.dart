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
    String umamiWebsiteId = 'website-id',
    String platform = 'android',
  }) {
    final client = MockClient((req) async {
      sink.add(req);
      return http.Response('', 202);
    });
    return AnalyticsService(
      client: client,
      umamiUrl: 'https://umami.test',
      umamiWebsiteId: umamiWebsiteId,
      umamiHostname: 'app.test',
      eventsApiUrl: 'https://api.test',
      installId: '11111111-1111-4111-8111-111111111111',
      platform: platform,
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

  test('track posts to Umami immediately as a named event', () async {
    final sink = <http.Request>[];
    final svc = build(enabled: true, sink: sink);
    svc.track('session_opened', props: {'surface': 'mobile'});
    await Future<void>.delayed(Duration.zero);
    final umami = sink.firstWhere((r) => r.url.host == 'umami.test');
    final body = jsonDecode(umami.body) as Map<String, dynamic>;
    final payload = body['payload'] as Map<String, dynamic>;
    // `name` is what makes this a custom event rather than a pageview — without
    // it Umami stores the same beacon as a view of `url`, and the whole event
    // report would be empty while the numbers still moved.
    expect(payload['name'], 'session_opened');
    expect(payload['website'], 'website-id');
    expect(payload['hostname'], 'app.test');
    expect(payload['data']['surface'], 'mobile');
    // Zero-knowledge invariant: installId must never appear in the Umami body.
    // This sink is the anonymous one; the whole point of the split is that it
    // cannot be joined to the identified first-party ingest below.
    const id = '11111111-1111-4111-8111-111111111111';
    expect(payload.containsKey('installId'), isFalse);
    expect(jsonEncode(body).contains(id), isFalse);
  });

  test('an empty website id makes the Umami beacon inert', () async {
    // The only thing keeping `flutter run` out of the production numbers, and
    // nothing else enforces it: the website has a tracker that refuses an
    // unknown host, and there is no tracker here. A regression is silent in the
    // direction that costs — dev and CI traffic read back later as real usage.
    final sink = <http.Request>[];
    final svc = build(enabled: true, sink: sink, umamiWebsiteId: '');
    svc.track('session_opened');
    await Future<void>.delayed(Duration.zero);
    expect(sink.where((r) => r.url.host == 'umami.test'), isEmpty);
    // The first-party ingest is unaffected — a debug build still reports to its
    // own staging backend, so gating Umami costs no telemetry.
    await svc.flush();
    expect(sink.where((r) => r.url.host == 'api.test'), isNotEmpty);
  });

  test('the user agent carries the platform Umami parses the OS from', () async {
    // Umami reads the OS off this header and nowhere else, so a UA that lost
    // its platform token files every event under an unknown OS — visible only
    // as an empty column in a dashboard nobody checks against this test.
    final sink = <http.Request>[];
    build(enabled: true, sink: sink, platform: 'windows').track('app_active');
    await Future<void>.delayed(Duration.zero);
    final ua = sink.firstWhere((r) => r.url.host == 'umami.test')
        .headers['user-agent'];
    expect(ua, contains('Windows NT 10.0'));
    // Product first: the Cloudflare rules in front of the collect endpoint
    // block bot-shaped agents, so this string has to stay identifiable as ours.
    expect(ua, startsWith('Antgrid/1.0.0'));
  });

  test('an unrecognised platform still sends, without a bogus OS claim',
      () async {
    // `analyticsPlatformTag` answers 'unknown' for fuchsia. Dropping the event
    // would be worse than an unattributed one, and inventing an OS token worse
    // than both.
    final sink = <http.Request>[];
    build(enabled: true, sink: sink, platform: 'unknown').track('app_active');
    await Future<void>.delayed(Duration.zero);
    final ua = sink.firstWhere((r) => r.url.host == 'umami.test')
        .headers['user-agent'];
    expect(ua, 'Antgrid/1.0.0');
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
    // the Umami test above which asserts its absence there).
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
        umamiUrl: 'https://umami.test',
        umamiWebsiteId: 'website-id',
        umamiHostname: 'app.test',
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
      // Umami body shares the same clamped map.
      final umami = sink.firstWhere((r) => r.url.host == 'umami.test');
      final ubody = jsonDecode(umami.body) as Map<String, dynamic>;
      final data = ubody['payload']['data'] as Map<String, dynamic>;
      expect((data['big'] as String).length, 120);
    },
  );
}
