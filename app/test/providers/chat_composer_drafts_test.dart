import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/chat_composer_drafts.dart';

void main() {
  test('removing a session releases its composer draft', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final drafts = container.read(chatComposerDraftsProvider);
    final original = drafts.forSession('session-a');

    clearChatComposerDraft(container, 'session-a');
    final replacement = drafts.forSession('session-a');

    expect(identical(replacement, original), isFalse);
    expect(replacement.isEmpty, isTrue);
  });
}
