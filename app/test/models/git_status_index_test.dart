import 'package:antgrid/models/ab_message.dart' show GitFileStatusEntry;
import 'package:antgrid/models/git_status_index.dart';
import 'package:flutter_test/flutter_test.dart';

// The other derivations are pinned by the Git panel's widget tests; this one
// surfaces only as Changes-tree row order, which no widget test isolates.
void main() {
  test('conflict ancestors cover the whole chain', () {
    final index = GitStatusIndex(const [
      GitFileStatusEntry(path: 'a/b/c/d.dart', status: '!', staged: false),
    ]);
    expect(index.dirsWithConflicts, {'a', 'a/b', 'a/b/c'});
  });
}
