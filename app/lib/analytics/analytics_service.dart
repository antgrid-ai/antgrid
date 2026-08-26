import 'dart:convert';
import 'package:http/http.dart' as http;

class AnalyticsService {
  AnalyticsService({
    required http.Client client,
    required String plausibleUrl,
    required String plausibleDomain,
    required String eventsApiUrl,
    required String installId,
    required String platform,
    required String appVersion,
    required bool Function() enabled,
    bool Function()? paused,
    DateTime Function()? now,
    this.batchSize = 10,
  }) : _client = client,
       _plausibleUrl = plausibleUrl.replaceAll(RegExp(r'/+$'), ''),
       _plausibleDomain = plausibleDomain,
       _eventsApiUrl = eventsApiUrl.replaceAll(RegExp(r'/+$'), ''),
       _installId = installId,
       _platform = platform,
       _appVersion = appVersion,
       _enabled = enabled,
       _paused = paused ?? _never,
       _now = now ?? DateTime.now;

  static bool _never() => false;

  final http.Client _client;
  final String _plausibleUrl;
  final String _plausibleDomain;
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
    _sendToPlausible(name, merged);
    _enqueue(name, merged);
  }

  // The first-party ingest caps prop string values at 120 chars and rejects the
  // WHOLE batch on any overflow. Clamp here so a single oversized value can
  // never 400 an otherwise-valid flush. Non-string values pass through.
  Map<String, Object?> _clampProps(Map<String, Object?> props) => props.map(
    (k, v) =>
        MapEntry(k, v is String && v.length > 120 ? v.substring(0, 120) : v),
  );

  void _sendToPlausible(String name, Map<String, Object?> props) {
    // Fire-and-forget. A realistic UA avoids Plausible's bot filtering.
    _client
        .post(
          Uri.parse('$_plausibleUrl/api/event'),
          headers: {
            'content-type': 'application/json',
            'user-agent': 'Antgrid/$_appVersion ($_platform)',
          },
          body: jsonEncode({
            'name': name,
            'domain': _plausibleDomain,
            'url': 'app://antgrid/$name',
            'props': props,
          }),
        )
        .ignore();
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
