import 'dart:io';

import 'package:antgrid/project/project_message_classification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart checkout-variable contract matches the bridge contract', () {
    final source = File('../bridge/src/protocol.ts').readAsStringSync();
    const marker = 'export const CHECKOUT_VARIABLE_MESSAGE_TYPES';
    final start = source.indexOf(marker);
    final end = source.indexOf(']);', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final block = source.substring(start, end);
    final bridgeTypes = RegExp(
      r'"([a-z][a-z0-9:-]+)"',
    ).allMatches(block).map((match) => match.group(1)!).toSet();

    expect(kCheckoutVariableMessageTypes, bridgeTypes);
  });

  test(
    'missing legacy checkoutId defaults to main without rewriting explicit ids',
    () {
      expect(checkoutIdForEnvelope({'type': 'tree:full'}), 'main');
      expect(
        checkoutIdForEnvelope({
          'type': 'tree:full',
          'checkoutId': 'checkout-1',
        }),
        'checkout-1',
      );
    },
  );
}
