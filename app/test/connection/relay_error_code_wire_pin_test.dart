// ConnectionSupervisor.noteRelayError classifies relay verdicts by matching
// the wire `error.code` STRINGS (LICENSE_* → Blocked(license…), SUPERSEDED →
// Blocked(superseded)). Nothing type-checks those strings against the wire
// enum — the envelope-vector fixture is regenerated from antgrid-wire's
// ErrorCode source of truth, so asserting membership here means a wire-side
// rename/removal breaks this test instead of silently un-classifying license
// errors on devices (a user whose license expired would just see a
// connection that never climbs).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('supervisor-classified error codes exist on the wire', () {
    final fixture =
        jsonDecode(
              File(
                '../evals/fixtures/relay-envelope-vectors.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    final wireCodes = {
      for (final v in (fixture['server'] as List).cast<Map<String, dynamic>>())
        if ((v['json'] as Map<String, dynamic>)['type'] == 'error')
          (v['json'] as Map<String, dynamic>)['code'] as String,
    };

    // Keep in lockstep with the switch in ConnectionSupervisor.noteRelayError
    // (app/lib/connection/connection_supervisor.dart).
    const supervisorClassified = {
      'LICENSE_EXPIRED',
      'LICENSE_REVOKED',
      'LICENSE_INVALID',
      'SUPERSEDED',
    };

    expect(
      wireCodes.containsAll(supervisorClassified),
      isTrue,
      reason:
          'wire ErrorCode no longer carries ${supervisorClassified.difference(wireCodes)} — '
          'update ConnectionSupervisor.noteRelayError in the same change',
    );
  });
}
