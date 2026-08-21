// Reading a checkout-variable service through the main-checkout façade compiles,
// analyzes clean, and is wrong only in an isolated session — the failure is a
// button that reports itself handled while acting on a tree nobody is looking
// at. Two call sites had drifted this way before this guard existed.
//
// The set of checkout-variable services is READ OFF CheckoutServices rather than
// listed here, so a service added there is covered without anyone remembering to
// come back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `late final FileService fileService;` — the fields of [CheckoutServices].
final _checkoutField = RegExp(r'late final \w+ (\w+);');

/// A `focusedServiceOrNull` call plus enough of what follows to reach its picker
/// lambda, which may be on the next line and may name its parameter anything.
final _mainCheckoutRead = RegExp(
  r'focusedServiceOrNull\((?:[^;]{0,200}?)=>\s*\w+\.(\w+)',
  dotAll: true,
);

Set<String> _checkoutVariableServices() {
  final source = File('lib/project/project_session.dart').readAsStringSync();
  final start = source.indexOf('class CheckoutServices');
  expect(start, isNonNegative, reason: 'CheckoutServices moved or was renamed');
  final body = source.substring(start);
  final names = _checkoutField.allMatches(body).map((m) => m.group(1)!).toSet();
  expect(names, contains('fileService'), reason: 'field scrape found nothing');
  return names;
}

void main() {
  test('no checkout-variable service is read off the main checkout', () {
    final checkoutVariable = _checkoutVariableServices();
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in _mainCheckoutRead.allMatches(source)) {
        final service = match.group(1)!;
        if (!checkoutVariable.contains(service)) continue;
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${entity.path}:$line reads $service');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Use focusedCheckoutServiceOrNull for these — focusedServiceOrNull '
          'resolves the project\'s MAIN checkout, which is not the tree an '
          'isolated session has on screen:\n${offenders.join('\n')}',
    );
  });
}
