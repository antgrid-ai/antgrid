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

    expect(block, contains('...CLIPBOARD_MESSAGE_TYPES'));
    final clipboard = File(
      '../bridge/src/terminal-clipboard/protocol.ts',
    ).readAsStringSync();
    final registry = RegExp(
      r'export const clipboardMessages = \[([\s\S]*?)\] as const;',
    ).firstMatch(clipboard);
    expect(registry, isNotNull);
    expect(
      clipboard,
      contains(
        'CLIPBOARD_MESSAGE_TYPES = clipboardMessages.map((schema) => schema.shape.type.value)',
      ),
    );
    for (final schema in RegExp(
      r'\bTerminalClipboard\w+Message\b',
    ).allMatches(registry!.group(1)!)) {
      final declaration = RegExp(
        'export const ${schema.group(0)} = context\\.extend\\(\\{'
        r'\s*type:\s*z\.literal\("([^"]+)"\)',
      ).firstMatch(clipboard);
      expect(declaration, isNotNull, reason: schema.group(0));
      bridgeTypes.add(declaration!.group(1)!);
    }

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
