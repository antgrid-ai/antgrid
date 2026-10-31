import 'package:antgrid/analytics/crash_reporting.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../helpers/recording_warning_sink.dart';

void main() {
  late RecordingWarningSink sink;
  late ConnectionBlockReporter reporter;

  setUp(() {
    sink = RecordingWarningSink();
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

  group('sign-out cleanup', () {
    test('captures a warning naming only the cause type', () {
      reportSignOutCleanupIncomplete(
        StateError('machine cleanup incomplete for 2 connection(s)'),
        sink: sink,
      );

      final capture = sink.captures.single;
      expect(capture.tags, {'sign_out.cleanup_cause': 'StateError'});
      expect(capture.fingerprint, [
        'sign-out-cleanup-incomplete',
        'StateError',
      ]);
      expect(capture.message, isNot(contains('machine cleanup')));
    });

    test('a throwing sink never escapes the report', () {
      sink.throwing = true;
      expect(
        () => reportSignOutCleanupIncomplete(StateError('x'), sink: sink),
        returnsNormally,
      );
    });
  });

  group('push keypair', () {
    late PushKeypairReporter keypair;
    setUp(() => keypair = PushKeypairReporter(sink: sink));

    PlatformException keychain(int status) => PlatformException(
      code: 'Unexpected security result code',
      message: 'Code: $status, Message: secret detail',
      details: status,
    );

    test('one warning per failure kind, keeping only the OSStatus', () {
      keypair.report(keychain(-25308));
      keypair.report(keychain(-25308));
      keypair.report(keychain(-34018));
      keypair.report(StateError('a message that must stay local'));

      expect(sink.captures.map((c) => c.tags['push.keypair_failure']), [
        'PlatformException:-25308',
        'PlatformException:-34018',
        'StateError',
      ]);
      for (final capture in sink.captures) {
        expect(capture.message, isNot(contains('detail')));
        expect(capture.message, isNot(contains('must stay local')));
      }
    });

    test('a throwing sink never escapes the report', () {
      sink.throwing = true;
      expect(() => keypair.report(StateError('x')), returnsNormally);
    });
  });
}
