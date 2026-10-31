import 'package:antgrid/analytics/crash_reporting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

typedef RecordedWarning = ({
  String message,
  Map<String, String> tags,
  List<String> fingerprint,
});

/// Stands in for Sentry behind a reporter, so a test can assert exactly what
/// would leave the device.
class RecordingWarningSink implements ConnectionBlockSink {
  final breadcrumbs = <Breadcrumb>[];
  final captures = <RecordedWarning>[];
  bool throwing = false;

  @override
  void addBreadcrumb(Breadcrumb breadcrumb) {
    if (throwing) throw StateError('sink');
    breadcrumbs.add(breadcrumb);
  }

  @override
  void captureWarning(
    String message, {
    required Map<String, String> tags,
    required List<String> fingerprint,
  }) {
    if (throwing) throw StateError('sink');
    captures.add((message: message, tags: tags, fingerprint: fingerprint));
  }
}
