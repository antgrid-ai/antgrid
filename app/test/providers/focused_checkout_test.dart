import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focused checkout follows the active managed session', () {
    final entry = SessionEntry(
      id: 'session-1',
      name: 'Session',
      createdAt: 1,
      lastUsedAt: 1,
      archived: false,
      running: true,
      checkoutId: 'checkout-1',
      checkoutKind: 'managed-worktree',
      checkoutBranch: 'antgrid/session-1',
    );
    final container = ProviderContainer(overrides: [
      activeSessionProvider.overrideWithValue(entry),
    ]);
    addTearDown(container.dispose);
    expect(container.read(focusedCheckoutIdProvider), 'checkout-1');
  });

  test('focused checkout defaults to main without an active session', () {
    final container = ProviderContainer(overrides: [
      activeSessionProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    expect(container.read(focusedCheckoutIdProvider), 'main');
  });
}
