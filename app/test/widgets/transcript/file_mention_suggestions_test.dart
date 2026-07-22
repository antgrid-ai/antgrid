import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/transcript/file_mention_suggestions.dart';

FileNode _file(String path) =>
    FileNode(name: path.split('/').last, path: path, type: FileNodeType.file);

FileNode _dir(String path, [List<FileNode> children = const []]) => FileNode(
  name: path.split('/').last,
  path: path,
  type: FileNodeType.directory,
  children: children,
);

FileNode _root(List<FileNode> children) => FileNode(
  name: '',
  path: '',
  type: FileNodeType.directory,
  children: children,
);

void main() {
  group('flattenFileTree', () {
    test('null root yields empty list', () {
      expect(flattenFileTree(null), isEmpty);
    });

    test('skips the root node, yields nested files and dirs with isDir', () {
      final root = _root([
        _file('README.md'),
        _dir('lib', [
          _file('lib/main.dart'),
          _dir('lib/src', [_file('lib/src/util.dart')]),
        ]),
      ]);
      final flat = flattenFileTree(root);
      expect(
        flat,
        containsAll(<FileMention>[
          (path: 'README.md', isDir: false),
          (path: 'lib', isDir: true),
          (path: 'lib/main.dart', isDir: false),
          (path: 'lib/src', isDir: true),
          (path: 'lib/src/util.dart', isDir: false),
        ]),
      );
      expect(flat, hasLength(5));
    });
  });

  group('filterFileMentions', () {
    final all = flattenFileTree(
      _root([
        _file('README.md'),
        _dir('lib', [
          _file('lib/main.dart'),
          _dir('lib/src', [
            _file('lib/src/util.dart'),
            _file('lib/src/zz_readme_notes.dart'),
          ]),
        ]),
        _dir('docs', [_file('docs/readme-guide.md')]),
      ]),
    );

    test('empty query: files before dirs, shallow-first, then alpha', () {
      final got = filterFileMentions(all, '');
      expect(got.map((e) => e.path).toList(), [
        'README.md',
        'docs/readme-guide.md',
        'lib/main.dart',
        'lib/src/util.dart',
        'lib/src/zz_readme_notes.dart',
        'docs',
        'lib',
        'lib/src',
      ]);
    });

    test('rank: filename-prefix beats filename-substring beats path-only', () {
      final candidates = flattenFileTree(
        _root([
          _dir('readme', [_file('readme/other.txt')]),
          _file('zz_readme_notes.dart'),
          _file('readme-guide.md'),
        ]),
      );
      final got = filterFileMentions(candidates, 'readme');
      expect(got.map((e) => e.path).toList(), [
        'readme-guide.md', // rank 0: filename starts with query
        'zz_readme_notes.dart', // rank 1: filename contains query
        'readme/other.txt', // rank 2: only the path contains query
        'readme', // dir, after all files
      ]);
    });

    test('matching is case-insensitive', () {
      final got = filterFileMentions(all, 'ReAdMe');
      expect(got.map((e) => e.path), contains('README.md'));
      expect(got.map((e) => e.path), contains('docs/readme-guide.md'));
    });

    test('files sort before dirs even when the dir ranks better', () {
      final candidates = flattenFileTree(
        _root([
          _dir('src', [_file('src/deep.txt')]),
        ]),
      );
      final got = filterFileMentions(candidates, 'src');
      expect(got.map((e) => e.path).toList(), ['src/deep.txt', 'src']);
    });

    test('caps results at limit', () {
      final many = _root([for (var i = 0; i < 60; i++) _file('f$i.txt')]);
      expect(filterFileMentions(flattenFileTree(many), ''), hasLength(50));
    });

    test('a matched directory stays reachable past the cap', () {
      // A folder with more descendant files than the whole cap. Every file
      // path-matches the query and sorts ahead of the dir, so a plain
      // take(limit) would truncate `widgets` itself — the folder the user is
      // most likely reaching for — leaving it unselectable.
      final root = _root([
        _dir('widgets', [
          for (var i = 0; i < 60; i++) _file('widgets/w$i.dart'),
        ]),
      ]);
      final got = filterFileMentions(flattenFileTree(root), 'widgets');
      expect(got, hasLength(50));
      expect(got.map((e) => e.path), contains('widgets'));
    });

    test('no match yields empty', () {
      expect(filterFileMentions(all, 'nope-zzz'), isEmpty);
    });
  });
}
