import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/analytics/install_id.dart';

void main() {
  test('ensure() returns a stable uuid across calls', () async {
    final store = InMemoryInstallIdStore();
    final a = await store.ensure();
    final b = await store.ensure();
    expect(a, isNotEmpty);
    expect(a, equals(b));
    expect(a.length, 36); // canonical uuid v4
  });

  test('different stores generate different ids', () async {
    final a = await InMemoryInstallIdStore().ensure();
    final b = await InMemoryInstallIdStore().ensure();
    expect(a, isNot(equals(b)));
  });
}
