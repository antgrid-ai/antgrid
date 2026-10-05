import 'ab_message.dart' show GitFileStatusEntry;

/// Everything the Git tab, the Files tab's decorations and the workspace menu
/// derive from one `git:status` reply, built once per reply.
///
/// Immutable by construction, so a holder compares it by identity and a
/// consumer never needs a "pass a fresh list, never edit in place" contract.
/// Each derivation is lazy: a status push costs nothing for the surfaces that
/// are not on screen, and a derivation costs one pass however many readers ask.
class GitStatusIndex {
  GitStatusIndex(this.entries);

  static final empty = GitStatusIndex(const []);

  /// The raw per-entry list. A path with both a staged and an unstaged change
  /// appears twice.
  final List<GitFileStatusEntry> entries;

  /// Entries grouped by path, in arrival order within a path.
  late final Map<String, List<GitFileStatusEntry>> byPath = _byPath();

  /// The ancestors of every CONFLICTED path: what lets a folder sort ahead of
  /// its siblings for holding one somewhere below.
  late final Set<String> dirsWithConflicts = _dirsWithConflicts();

  /// Every directory prefix of every changed path, which is exactly the set of
  /// folder rows the changed-files tree produces. Derived from the paths rather
  /// than the rendered tree because the header exists before any tree does.
  late final Set<String> changedFolders = {
    for (final e in entries) ..._ancestorsOf(e.path),
  };

  late final int stagedCount = entries.where((e) => e.staged).length;

  /// A conflict ("!") is included — staging one IS how git resolves it, so
  /// Stage All has to reach it.
  late final List<String> unstagedPaths = [
    for (final e in entries)
      if (!e.staged) e.path,
  ];

  /// Deduped, because a partially staged path has two entries and Revert All
  /// names each once. Never a conflict: resolving one is not a restore to HEAD.
  late final List<String> revertablePaths = [
    ...{
      for (final e in entries)
        if (e.status != '!') e.path,
    },
  ];

  /// Unmerged paths, resolved or not. Git refuses a commit while ANY is
  /// unmerged.
  late final List<String> conflictPaths = [
    for (final e in entries)
      if (e.isConflict) e.path,
  ];

  /// The conflicts whose markers are still in the file, which staging would
  /// resolve on the user's word alone.
  late final List<String> unresolvedConflictPaths = [
    for (final e in entries)
      if (e.isUnresolvedConflict) e.path,
  ];

  /// Distinct changed paths, conflicts included.
  int get changedCount => byPath.length;

  /// Whether anything at all is changed. A conflict counts, which is why this
  /// is not `revertablePaths.isNotEmpty`.
  bool get hasChanges => revertablePaths.isNotEmpty || conflictPaths.isNotEmpty;

  /// Lines added across distinct paths: both entries of a partially staged
  /// file carry the SAME combined-vs-HEAD counts, so summing entries doubles it.
  late final int additions = _firstPerPath().fold(0, (s, e) => s + e.additions);

  late final int deletions = _firstPerPath().fold(0, (s, e) => s + e.deletions);

  Iterable<GitFileStatusEntry> _firstPerPath() =>
      byPath.values.map((list) => list.first);

  Map<String, List<GitFileStatusEntry>> _byPath() {
    final out = <String, List<GitFileStatusEntry>>{};
    for (final e in entries) {
      out.putIfAbsent(e.path, () => []).add(e);
    }
    return out;
  }

  Set<String> _dirsWithConflicts() {
    final out = <String>{};
    for (final e in entries) {
      if (e.status != '!') continue;
      var dir = e.path;
      var slash = dir.lastIndexOf('/');
      while (slash >= 0) {
        dir = dir.substring(0, slash);
        // Already recorded => every ancestor above it was too.
        if (!out.add(dir)) break;
        slash = dir.lastIndexOf('/');
      }
    }
    return out;
  }

  /// The trailing slash git puts on an untracked directory it did not walk
  /// into is dropped first: the tree renders that path as a LEAF, so the name
  /// before the slash is not a folder row.
  static Iterable<String> _ancestorsOf(String path) sync* {
    var dir = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    var slash = dir.lastIndexOf('/');
    while (slash >= 0) {
      dir = dir.substring(0, slash);
      yield dir;
      slash = dir.lastIndexOf('/');
    }
  }
}
