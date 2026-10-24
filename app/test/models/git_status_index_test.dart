import 'package:antgrid/models/ab_message.dart' show GitFileStatusEntry;
import 'package:antgrid/models/git_status_index.dart';
import 'package:flutter_test/flutter_test.dart';

// The other derivations are pinned by the Git panel's widget tests; this one's
// identity is what lets each side's list reuse its rows, which no widget test
// can see.
void main() {
  test('each side keeps its entries, and is the same index on every read', () {
    final index = GitStatusIndex(const [
      GitFileStatusEntry(path: 'a.dart', status: 'M', staged: true),
      GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
      GitFileStatusEntry(path: 'b.dart', status: 'U', staged: false),
    ]);
    expect(index.staged.byPath.keys, ['a.dart']);
    expect(index.unstaged.byPath.keys, ['a.dart', 'b.dart']);
    expect(identical(index.staged, index.staged), isTrue);
  });
}
