import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/ab_status_helpers.dart';

void main() {
  group('sessionRefusalCopy', () {
    test('dedicated copy outranks the bridge\'s own wording', () {
      // The whole point of an arm in friendlyErrorCopy is that the bridge's
      // sentence names something the reader can't act on ("mobile access is
      // disabled on this machine" names neither the switch nor where it lives),
      // so a raw message must never win over one.
      final copy = sessionRefusalCopy(
        'NOT_ALLOWED',
        'mobile access is disabled on this machine',
        'Could not do that',
      );
      expect(copy, friendlyErrorCopy('NOT_ALLOWED'));
      expect(copy, isNot(contains('mobile access')));
    });

    test('a code with no arm keeps the bridge message verbatim', () {
      // WORKTREE_CREATE_FAILED spans causes as unlike as a locked checkout and a
      // repository with no commit; only the raw message says which.
      expect(
        sessionRefusalCopy(
          'WORKTREE_CREATE_FAILED',
          'fatal: invalid reference: nope',
          'Could not do that',
        ),
        'fatal: invalid reference: nope',
      );
    });

    test('neither a code nor a message falls back to the caller\'s copy', () {
      expect(sessionRefusalCopy(null, null, 'Could not do that'),
          'Could not do that');
    });
  });
}
