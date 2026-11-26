import 'package:antgrid/analytics/crash_reporting.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

typedef _Capture = ({
  String message,
  Map<String, String> tags,
  List<String> fingerprint,
});

class _RecordingSink implements ConnectionBlockSink {
  final breadcrumbs = <Breadcrumb>[];
  final captures = <_Capture>[];
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

void main() {
  late _RecordingSink sink;
  late ConnectionBlockReporter reporter;

  setUp(() {
    sink = _RecordingSink();
    reporter = ConnectionBlockReporter(sink: sink);
  });

  test('every block leaves a breadcrumb with only reason and code', () {
    reporter.report(BlockReason.licenseExpired, 'LICENSE_EXPIRED');

    expect(sink.breadcrumbs.single.category, 'connection');
    expect(sink.breadcrumbs.single.data, {
      'reason': 'licenseExpired',
      'code': 'LICENSE_EXPIRED',
    });
    expect(sink.captures, isEmpty);
  });

  test('stranding blocks capture one warning per reason and code', () {
    for (var i = 0; i < 3; i++) {
      reporter.report(BlockReason.peerRejected, 'PEER_IDENTITY_DENIED');
    }
    reporter.report(
      BlockReason.peerRejected,
      'AUTHENTICATED_ENDPOINT_MISMATCH',
    );
    reporter.report(BlockReason.handshakeFailing, null);
    reporter.report(BlockReason.handshakeFailing, null);
    reporter.report(BlockReason.deviceRevoked, 'LICENSE_INVALID');

    expect(sink.breadcrumbs.length, 7);
    expect(sink.captures.length, 4);
    expect(sink.captures.first.tags, {
      'connection.block_reason': 'peerRejected',
      'connection.failure_code': 'PEER_IDENTITY_DENIED',
    });
    expect(sink.captures.first.fingerprint, [
      'connection-blocked',
      'peerRejected',
      'PEER_IDENTITY_DENIED',
    ]);
    final handshake = sink.captures.firstWhere(
      (c) => c.tags['connection.block_reason'] == 'handshakeFailing',
    );
    expect(handshake.tags['connection.failure_code'], 'NONE');
  });

  test('codes that are not identifier-shaped never leave the device', () {
    reporter.report(
      BlockReason.peerRejected,
      'Bad state: /Users/me/p wss://relay.example',
    );
    reporter.report(BlockReason.peerRejected, 'ab12cd');

    final sent = <String>[
      for (final b in sink.breadcrumbs) ...[
        b.data!['code'] as String,
        b.message ?? '',
      ],
      for (final c in sink.captures) ...[
        c.message,
        ...c.tags.values,
        ...c.fingerprint,
      ],
    ];
    expect(sink.captures.length, 1);
    expect(sink.breadcrumbs.map((b) => b.data!['code']), [
      'UNRECOGNIZED',
      'UNRECOGNIZED',
    ]);
    expect(sink.captures.single.message, contains('UNRECOGNIZED'));
    for (final value in sent) {
      expect(value, isNot(contains('relay.example')));
      expect(value, isNot(contains('/Users')));
      expect(value, isNot(contains('ab12cd')));
    }
  });

  test('reportableFailureCode maps null and malformed codes', () {
    expect(reportableFailureCode(null), 'NONE');
    expect(reportableFailureCode('LEASE_EXPIRED'), 'LEASE_EXPIRED');
    expect(reportableFailureCode('lease_expired'), 'UNRECOGNIZED');
    expect(reportableFailureCode('A' * 65), 'UNRECOGNIZED');
  });

  test('capturesConnectionBlock decides by reason', () {
    for (final reason in BlockReason.values) {
      expect(
        capturesConnectionBlock(reason),
        reason != BlockReason.licenseExpired,
        reason: reason.name,
      );
    }
  });

  test('a throwing sink never escapes report', () {
    sink.throwing = true;
    expect(
      () => reporter.report(BlockReason.peerRejected, 'X'),
      returnsNormally,
    );
  });

  test('the default sink is a no-op without an initialised Sentry', () {
    expect(Sentry.isEnabled, isFalse);
    expect(
      () => ConnectionBlockReporter().report(BlockReason.peerRejected, 'X'),
      returnsNormally,
    );
  });
}
