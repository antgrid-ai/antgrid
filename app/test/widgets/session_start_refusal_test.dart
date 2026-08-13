import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/session_start_refusal.dart';

void main() {
  group('sessionStartRefusalCopy', () {
    test('a missing checkout names both remedies, and no mechanism', () {
      final copy = sessionStartRefusalCopy(
        'WORKTREE_MISSING',
        'The isolated worktree is no longer available.',
      );

      expect(copy, contains(friendlyErrorCopy('WORKTREE_MISSING')!));
      expect(copy, contains('Restore its folder'));
      expect(copy, contains('delete the session'));
      // The badge, the composer chip and the shared error copy all refuse to
      // name the backend; a remedy sentence must not be the one place that does.
      expect(copy.toLowerCase(), isNot(contains('worktree')));
    });

    test('another coded refusal keeps its own copy and steers nowhere', () {
      // Only the one code whose sole remedy is restore-or-delete may mention
      // deleting. Every other arm has a fix that keeps the session.
      final copy = sessionStartRefusalCopy(
        'WORKTREE_WORKING_DIR_UNSAFE',
        'agent.workingDir escapes the checkout',
      );

      expect(copy, friendlyErrorCopy('WORKTREE_WORKING_DIR_UNSAFE'));
      expect(copy.toLowerCase(), isNot(contains('delete')));
    });

    test('an unmapped code keeps the bridge message', () {
      expect(
        sessionStartRefusalCopy('WORKTREE_CREATE_FAILED', 'git said no'),
        'git said no',
      );
    });

    test('a refusal carrying neither falls back', () {
      expect(
        sessionStartRefusalCopy(null, null),
        'Could not start this session.',
      );
    });
  });

  test('friendlyErrorCopy\'s WORKTREE_MISSING arm never mentions deleting', () {
    // Three of the code's five producers fire on the DELETE path, where the
    // delete ladder renders this arm mid-delete — steering the user to delete
    // there is advice they have already taken. The remedy sentence is why
    // sessionStartRefusalCopy exists as a separate layer.
    expect(
      friendlyErrorCopy('WORKTREE_MISSING')!.toLowerCase(),
      isNot(contains('delet')),
    );
  });
}
