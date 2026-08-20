// The worktree's +/- is the one figure that says how big a session's work got,
// and it is derived twice — once for the workspace menu, once for the git
// panel's changes header. This pins the derivation both share: a path changed
// on BOTH sides arrives twice and must still be counted once.
import 'package:antgrid/models/ab_message.dart' show GitFileStatusEntry;
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

GitFileStatusEntry _entry(
  String path, {
  bool staged = false,
  int additions = 0,
  int deletions = 0,
}) => GitFileStatusEntry(
  path: path,
  status: 'M',
  staged: staged,
  additions: additions,
  deletions: deletions,
);

ProviderContainer _containerWith(List<GitFileStatusEntry> entries) {
  final c = ProviderContainer(
    overrides: [
      fileTreeStateProvider.overrideWith(
        (ref) => Stream.value(FileTreeState(gitFileEntries: entries)),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<GitDiffTotals> _totals(List<GitFileStatusEntry> entries) async {
  final c = _containerWith(entries);
  // A listener, not a bare read: the override is a Stream, so the value lands
  // a microtask later and nothing would keep the provider alive until then.
  c.listen(gitDiffTotalsProvider, (_, _) {});
  await Future<void>.delayed(Duration.zero);
  return c.read(gitDiffTotalsProvider);
}

void main() {
  test('a clean tree totals zero', () async {
    expect(await _totals(const []), (additions: 0, deletions: 0));
  });

  test('a partially staged path counts once', () async {
    // Both entries carry the same combined-vs-HEAD counts (the bridge computes
    // one diff per path), so summing entries would double this file.
    expect(
      await _totals([
        _entry('a.dart', additions: 10, deletions: 4),
        _entry('a.dart', staged: true, additions: 10, deletions: 4),
        _entry('b.dart', additions: 3, deletions: 0),
      ]),
      (additions: 13, deletions: 4),
    );
  });
}
