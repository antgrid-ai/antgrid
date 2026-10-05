import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/drawer_expansion.dart';

void main() {
  test('a local selection unfolds This machine', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(localMachineCollapsedProvider.notifier).toggle();
    expect(c.read(localMachineCollapsedProvider), isTrue);

    revealDrawerSelection(c, 'local-project');

    expect(c.read(localMachineCollapsedProvider), isFalse);
    expect(c.read(expandedDrawerIdsProvider), isEmpty);
  });

  test('a remote selection opens its machine and its project row', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    revealDrawerSelection(c, 'uuid-1.proj-9');

    expect(c.read(expandedDrawerIdsProvider), {'uuid-1', 'uuid-1.proj-9'});
    expect(c.read(localMachineCollapsedProvider), isFalse);
  });
}
