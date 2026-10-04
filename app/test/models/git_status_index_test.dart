import 'package:antgrid/models/ab_message.dart' show GitFileStatusEntry;
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/git_status_index.dart';
import 'package:flutter_test/flutter_test.dart';

GitFileStatusEntry _e(
  String path, {
  String status = 'M',
  bool staged = false,
  int additions = 0,
  int deletions = 0,
}) => GitFileStatusEntry(
  path: path,
  status: status,
  staged: staged,
  additions: additions,
  deletions: deletions,
);

void main() {
  test('the empty index reports nothing changed', () {
    final index = GitStatusIndex.empty;
    expect(index.hasChanges, isFalse);
    expect(index.changedCount, 0);
    expect(index.additions, 0);
    expect(index.changedFolders, isEmpty);
  });

  test('a partially staged path counts once in totals and changed count', () {
    final index = GitStatusIndex([
      _e('a.dart', additions: 10, deletions: 4),
      _e('a.dart', staged: true, additions: 10, deletions: 4),
      _e('b.dart', additions: 3),
    ]);
    expect(index.changedCount, 2);
    expect(index.additions, 13);
    expect(index.deletions, 4);
    expect(index.stagedCount, 1);
    expect(index.unstagedPaths, ['a.dart', 'b.dart']);
    expect(index.revertablePaths, ['a.dart', 'b.dart']);
    expect(index.byPath['a.dart'], hasLength(2));
  });

  test('a conflict is unstaged and counted but never revertable', () {
    final index = GitStatusIndex([
      _e('src/x.dart', status: '!'),
      _e('y.dart'),
    ]);
    expect(index.conflictPaths, ['src/x.dart']);
    expect(index.revertablePaths, ['y.dart']);
    expect(index.unstagedPaths, contains('src/x.dart'));
    expect(index.hasChanges, isTrue);
    expect(index.dirsWithConflicts, {'src'});
  });

  test('a conflict-only tree still has changes', () {
    expect(GitStatusIndex([_e('a', status: '!')]).hasChanges, isTrue);
  });

  test('changed folders are every directory prefix, minus a trailing slash', () {
    final index = GitStatusIndex([
      _e('a/b/c.dart'),
      _e('top.dart'),
      _e('untracked/dir/', status: 'U'),
    ]);
    expect(index.changedFolders, {'a', 'a/b', 'untracked'});
  });

  test('conflict ancestors cover the whole chain', () {
    final index = GitStatusIndex([_e('a/b/c/d.dart', status: '!')]);
    expect(index.dirsWithConflicts, {'a', 'a/b', 'a/b/c'});
  });

  test('a tree-side copyWith keeps the status index instance', () {
    final index = GitStatusIndex([_e('a.dart')]);
    final state = FileTreeState(gitStatus: index);
    expect(
      identical(state.copyWith(expandedPaths: {'x'}).gitStatus, index),
      isTrue,
    );
    expect(state.gitFileEntries, same(index.entries));
  });
}
