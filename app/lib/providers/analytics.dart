import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../analytics/analytics_service.dart';

/// Overridden in main() once the install id is resolved. Null-safe consumers
/// should `ref.read(analyticsServiceProvider)?.track(...)`.
final analyticsServiceProvider = Provider<AnalyticsService?>((ref) => null);

/// Used by main() to build the service after async install-id resolution.
AnalyticsService buildAnalyticsService({
  required http.Client client,
  required String installId,
  required String platform,
  required String appVersion,
  required bool Function() enabled,
  required bool Function() paused,
  required String plausibleUrl,
  required String plausibleDomain,
  required String eventsApiUrl,
}) => AnalyticsService(
  client: client,
  plausibleUrl: plausibleUrl,
  plausibleDomain: plausibleDomain,
  eventsApiUrl: eventsApiUrl,
  installId: installId,
  platform: platform,
  appVersion: appVersion,
  enabled: enabled,
  paused: paused,
);
