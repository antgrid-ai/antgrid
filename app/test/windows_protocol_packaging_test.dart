import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows protocol packaging', () {
    test('MSIX declares the antgrid protocol', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, contains('  protocol_activation: antgrid'));
    });
  });
}
