import 'dart:convert';
import 'package:http/http.dart' as http;

class AnalyticsService {
  AnalyticsService({
    required http.Client client,
    required String umamiUrl,
    required String umamiWebsiteId,
    required String umamiHostname,
    required String eventsApiUrl,
    required String installId,
    required String platform,
    required String appVersion,
    required bool Function() enabled,
    bool Function()? paused,
    DateTime Function()? now,
    this.batchSize = 10,
  }) : _client = client,
       _umamiUrl = umamiUrl.replaceAll(RegExp(r'/+$'), ''),
       _umamiWebsiteId = umamiWebsiteId,
       _umamiHostname = umamiHostname,
       _userAgent = _userAgentFor(platform, appVersion),
       _eventsApiUrl = eventsApiUrl.replaceAll(RegExp(r'/+$'), ''),
       _installId = installId,
       _platform = platform,
       _appVersion = appVersion,
       _enabled = enabled,
       _paused = paused ?? _never,
       _now = now ?? DateTime.now;

  static bool _never() => false;

  final http.Client _client;
  final String _umamiUrl;
  final String _umamiWebsiteId;
  final String _umamiHostname;
  final String _userAgent;
  final String _eventsApiUrl;
  final String _installId;
  final String _platform;
  final String _appVersion;
  final bool Function() _enabled;

  /// A temporary hold, distinct from [_enabled]: see [flush].
  final bool Function() _paused;
  final DateTime Function() _now;
  final int batchSize;

  final List<Map<String, Object?>> _queue = [];

  void track(String name, {Map<String, Object?> props = const {}}) {
    if (!_enabled()) return;
    final merged = {'platform': _platform, ..._clampProps(props)};
    _sendToUmami(name, merged);
    _enqueue(name, merged);
  }

  // The first-party ingest caps prop string values at 120 chars and rejects the
  // WHOLE batch on any overflow. Clamp here so a single oversized value can
  // never 400 an otherwise-valid flush. Non-string values pass through.
  Map<String, Object?> _clampProps(Map<String, Object?> props) => props.map(
    (k, v) =>
        MapEntry(k, v is String && v.length > 120 ? v.substring(0, 120) : v),
  );

  /// The anonymous half of the split: this sink must never be able to be joined
  /// to the first-party one, so [_installId] is deliberately absent from the
  /// body and belongs only in [_enqueue].
  ///
  /// An empty website id means the beacon is inert — see
  /// `AppEnvironment.umamiWebsiteId` for why that is the whole of the dev gate.
  void _sendToUmami(String name, Map<String, Object?> props) {
    if (_umamiWebsiteId.isEmpty) return;
    // Fire-and-forget.
    _client
        .post(
          Uri.parse('$_umamiUrl/api/send'),
          headers: {
            'content-type': 'application/json',
            'user-agent': _userAgent,
          },
          body: jsonEncode({
            'type': 'event',
            'payload': {
              'website': _umamiWebsiteId,
              'hostname': _umamiHostname,
              // Umami keys its own filters on a url path, so one path per
              // event name is what makes those filters reach an app event at
              // all. It does not pollute the page report this website id also
              // carries for the web app (web/src/ui/analytics.tsx): those
              // reports select on Umami's pageview event_type, which a beacon
              // carrying `name` is not.
              'url': '/$name',
              'name': name,
              'data': props,
            },
          }),
        )
        .ignore();
  }

  /// Umami reads the operating system off the User-Agent and from nowhere else,
  /// so an agent naming only the product files every event under an unknown OS.
  /// The parenthesised token is there for that parser — the smallest string it
  /// matches per platform — while the product token stays first, so this
  /// identifies our client rather than impersonating a browser.
  ///
  /// Two other things read this string and both are silent when they refuse:
  /// the Cloudflare rules in front of the collect endpoint block bot-shaped
  /// agents, and Umami runs `isbot` over it before storing anything (a match is
  /// answered 200 and dropped). A missing event is never by itself evidence of
  /// a bug on this side.
  ///
  /// Keys are the tags `analyticsPlatformTag` returns (app/lib/analytics/
  /// events.dart), which are themselves kept in lockstep with a Zod enum in
  /// web/src/routes/events.ts — so a rename there lands here too. A key that
  /// stops matching costs that platform its OS token and nothing else: the
  /// event still sends, and no test sees it.
  static String _userAgentFor(String platform, String appVersion) {
    const tokens = {
      'windows': 'Windows NT 10.0; Win64; x64',
      'macos': 'Macintosh; Intel Mac OS X',
      'linux': 'X11; Linux x86_64',
      'android': 'Linux; Android',
      'ios': 'iPhone; like Mac OS X',
    };
    final token = tokens[platform];
    return token == null
        ? 'Antgrid/$appVersion'
        : 'Antgrid/$appVersion ($token)';
  }

  void _enqueue(String name, Map<String, Object?> props) {
    _queue.add({
      'installId': _installId,
      'name': name,
      'ts': _now().toUtc().toIso8601String(),
      'platform': _platform,
      'appVersion': _appVersion,
      'props': props,
    });
    if (_queue.length >= batchSize) flush();
  }

  Future<void> flush() async {
    // A pause is not an opt-out. The queue holds the user's OWN events from
    // before they entered the sample project, which they had consented to
    // send; hold them until the pause lifts rather than dropping them.
    if (_paused()) return;
    // Honor a runtime opt-out: track() stops enqueuing once disabled, but the
    // pause-lifecycle flush would otherwise still transmit events queued while
    // telemetry was on. Drop them instead.
    if (!_enabled()) {
      _queue.clear();
      return;
    }
    if (_queue.isEmpty) return;
    final batch = List<Map<String, Object?>>.from(_queue);
    _queue.clear();
    try {
      await _client.post(
        Uri.parse('$_eventsApiUrl/events'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'events': batch}),
      );
    } catch (_) {
      // Drop on failure — losing a few anonymous events is acceptable.
    }
  }
}
