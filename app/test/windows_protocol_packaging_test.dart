import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows protocol packaging', () {
    test('MSIX declares the antgrid protocol', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, contains('  protocol_activation: antgrid'));
    });

    test('Inno registers and removes the antgrid protocol', () {
      final installer = File(
        'windows/installer/antgrid.iss',
      ).readAsStringSync();

      expect(installer, contains('ChangesAssociations=yes'));
      expect(
        installer,
        contains(
          r'Root: HKCU; Subkey: "Software\Classes\antgrid"; ValueType: string; ValueName: ""; ValueData: "URL:Antgrid Protocol"; Flags: uninsdeletekey',
        ),
      );
      expect(
        installer,
        contains(
          r'Root: HKCU; Subkey: "Software\Classes\antgrid"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""',
        ),
      );
      expect(
        installer,
        contains(
          r'Root: HKCU; Subkey: "Software\Classes\antgrid\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\antgrid.exe"" ""%1"""',
        ),
      );
    });
  });
}
