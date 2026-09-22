// Pins the relay verdict strings the supervisor classifies. License verdicts
// stop the native session through enrollment invalidation; SUPERSEDED only
// stops central-control retries and leaves a healthy leased payload intact.
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
