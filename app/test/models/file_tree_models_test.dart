import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/file_tree_models.dart';

void main() {
  group('FileNodeType', () {
    test('file enum matches "file" string', () {
      expect(FileNodeType.file.name, 'file');
    });

    test('directory enum matches "directory" string', () {
      expect(FileNodeType.directory.name, 'directory');
    });
  });

  group('FileNode.fromJson', () {
    test('parses a flat file node', () {
      final json = {
        'name': 'foo.ts',
        'path': 'src/foo.ts',
        'type': 'file',
        'size': 123,
        'extension': '.ts',
      };
      final node = FileNode.fromJson(json);
      expect(node, isNotNull);
      expect(node!.name, 'foo.ts');
      expect(node.path, 'src/foo.ts');
      expect(node.type, FileNodeType.file);
      expect(node.size, 123);
      expect(node.extension, '.ts');
      expect(node.children, isEmpty);
    });

    test('parses a directory with children recursively', () {
      final json = {
        'name': 'src',
        'path': 'src',
        'type': 'directory',
        'children': [
          {
            'name': 'utils',
            'path': 'src/utils',
            'type': 'directory',
            'children': [
              {
                'name': 'helper.ts',
                'path': 'src/utils/helper.ts',
                'type': 'file',
                'size': 50,
              },
            ],
          },
          {
            'name': 'index.ts',
            'path': 'src/index.ts',
            'type': 'file',
            'size': 100,
          },
        ],
      };
      final node = FileNode.fromJson(json);
      expect(node, isNotNull);
      expect(node!.type, FileNodeType.directory);
      expect(node.children, hasLength(2));
      // directories first
      expect(node.children[0].name, 'utils');
      expect(node.children[0].type, FileNodeType.directory);
      expect(node.children[0].children, hasLength(1));
      expect(node.children[0].children[0].name, 'helper.ts');
      // then files
      expect(node.children[1].name, 'index.ts');
    });

    test('returns null for invalid JSON (missing name)', () {
      final json = {'path': 'src/foo.ts', 'type': 'file'};
      expect(FileNode.fromJson(json), isNull);
    });

    test('returns null for invalid JSON (missing path)', () {
      final json = {'name': 'foo.ts', 'type': 'file'};
      expect(FileNode.fromJson(json), isNull);
    });

    test('returns null for invalid JSON (missing type)', () {
      final json = {'name': 'foo.ts', 'path': 'src/foo.ts'};
      expect(FileNode.fromJson(json), isNull);
    });

    test('returns null for invalid type string', () {
      final json = {'name': 'foo.ts', 'path': 'src/foo.ts', 'type': 'symlink'};
      expect(FileNode.fromJson(json), isNull);
    });

    test('a file always reads childrenLoaded true, regardless of the wire', () {
      final node = FileNode.fromJson({
        'name': 'foo.ts',
        'path': 'src/foo.ts',
        'type': 'file',
      });
      expect(node, isNotNull);
      expect(node!.childrenLoaded, isTrue);
    });

    test(
      'a directory whose json carried a children list reads childrenLoaded true, even when empty',
      () {
        final node = FileNode.fromJson({
          'name': 'empty',
          'path': 'empty',
          'type': 'directory',
          'children': <Map<String, dynamic>>[],
        });
        expect(node, isNotNull);
        expect(node!.childrenLoaded, isTrue);
        expect(node.children, isEmpty);
      },
    );

    test(
      'a directory whose json carried no children key reads childrenLoaded false',
      () {
        // Depth-1 listing shape: a subdirectory named as an entry but not
        // itself recursed into.
        final node = FileNode.fromJson({
          'name': 'unexpanded',
          'path': 'unexpanded',
          'type': 'directory',
        });
        expect(node, isNotNull);
        expect(node!.childrenLoaded, isFalse);
        expect(node.children, isEmpty);
      },
    );

    test('childrenLoading is never read from the wire', () {
      final node = FileNode.fromJson({
        'name': 'foo.ts',
        'path': 'src/foo.ts',
        'type': 'file',
        'childrenLoading': true,
      });
      expect(node, isNotNull);
      expect(node!.childrenLoading, isFalse);
    });

    test('reads the ignored flag', () {
      final node = FileNode.fromJson({
        'name': 'dist',
        'path': 'dist',
        'type': 'directory',
        'ignored': true,
      });
      expect(node, isNotNull);
      expect(node!.ignored, isTrue);
    });

    test('ignored defaults to false when absent', () {
      final node = FileNode.fromJson({
        'name': 'src',
        'path': 'src',
        'type': 'directory',
      });
      expect(node, isNotNull);
      expect(node!.ignored, isFalse);
    });

    test('sorts children: directories first, then alphabetical by name', () {
      final json = {
        'name': 'root',
        'path': '',
        'type': 'directory',
        'children': [
          {'name': 'zebra.ts', 'path': 'zebra.ts', 'type': 'file'},
          {'name': 'alpha', 'path': 'alpha', 'type': 'directory'},
          {'name': 'beta.ts', 'path': 'beta.ts', 'type': 'file'},
          {'name': 'omega', 'path': 'omega', 'type': 'directory'},
        ],
      };
      final node = FileNode.fromJson(json);
      expect(node, isNotNull);
      // Directories first (alpha, omega), then files (beta.ts, zebra.ts)
      expect(node!.children.map((c) => c.name).toList(), [
        'alpha',
        'omega',
        'beta.ts',
        'zebra.ts',
      ]);
    });
  });

  group('FileNode rebuild hazard', () {
    // FileNode has no copyWith — every "rebuild" in the codebase (the merge
    // helpers in FileService, the synthetic Git-changes tree in
    // file_tree_view.dart) hand-writes `FileNode(...)` and must carry every
    // field forward itself, or a rebuild silently resets it to the
    // constructor default. This pins that a value CAN survive a hand rebuild
    // when carried explicitly — the same contract truncated already relies
    // on.
    test(
      'a hand rebuild that carries every field preserves childrenLoaded, childrenLoading, truncated and ignored',
      () {
        const original = FileNode(
          name: 'dist',
          path: 'dist',
          type: FileNodeType.directory,
          children: [],
          truncated: true,
          childrenLoaded: true,
          childrenLoading: true,
          ignored: true,
        );

        final rebuilt = FileNode(
          name: original.name,
          path: original.path,
          type: original.type,
          size: original.size,
          extension: original.extension,
          children: original.children,
          truncated: original.truncated,
          childrenLoaded: original.childrenLoaded,
          childrenLoading: original.childrenLoading,
          ignored: original.ignored,
        );

        expect(rebuilt.truncated, isTrue);
        expect(rebuilt.childrenLoaded, isTrue);
        expect(rebuilt.childrenLoading, isTrue);
        expect(rebuilt.ignored, isTrue);
      },
    );

    test(
      'a hand rebuild that OMITS a field silently resets it to the constructor default',
      () {
        const original = FileNode(
          name: 'dist',
          path: 'dist',
          type: FileNodeType.directory,
          childrenLoaded: false,
          childrenLoading: true,
          ignored: true,
        );

        // Forgets childrenLoaded/childrenLoading/ignored — exactly the
        // hazard this wave exists to make each call site avoid.
        final rebuilt = FileNode(
          name: original.name,
          path: original.path,
          type: original.type,
          children: original.children,
        );

        expect(rebuilt.childrenLoaded, isTrue); // default, NOT original.false
        expect(rebuilt.childrenLoading, isFalse); // default, NOT original.true
        expect(rebuilt.ignored, isFalse); // default, NOT original.true
      },
    );
  });

  group('FileTreeState', () {
    test('default constructor has correct defaults', () {
      const state = FileTreeState();
      expect(state.root, isNull);
      expect(state.expandedPaths, isEmpty);
      expect(state.files.selectedFilePath, isNull);
      expect(state.files.viewingFile, isNull);
      expect(state.files.isLoading, isFalse);
      expect(state.filterQuery, isNull);
      expect(state.projectId, isNull);
    });

    test('copyWith preserves expandedPaths when updating root', () {
      final root = FileNode.fromJson({
        'name': 'root',
        'path': '',
        'type': 'directory',
      })!;
      const state = FileTreeState(expandedPaths: {'src', 'lib'});
      final newState = state.copyWith(root: root);
      expect(newState.root, isNotNull);
      expect(newState.expandedPaths, {'src', 'lib'});
    });

    test('copyWith can update individual fields', () {
      const state = FileTreeState();
      final updated = state.copyWith(
        files: state.files.copyWith(
          isLoading: true,
          selectedFilePath: 'foo.ts',
        ),
        filterQuery: 'test',
        projectId: 'proj-1',
      );
      expect(updated.files.isLoading, isTrue);
      expect(updated.files.selectedFilePath, 'foo.ts');
      expect(updated.filterQuery, 'test');
      expect(updated.projectId, 'proj-1');
    });
  });

  group('FileContent', () {
    test('stores path and content', () {
      const fc = FileContent(path: 'src/main.ts', content: 'hello', size: 5);
      expect(fc.path, 'src/main.ts');
      expect(fc.content, 'hello');
      expect(fc.size, 5);
      expect(fc.error, isNull);
    });

    test('stores error when content unavailable', () {
      const fc = FileContent(
        path: 'missing.ts',
        content: null,
        size: 0,
        error: 'File not found',
      );
      expect(fc.content, isNull);
      expect(fc.error, 'File not found');
    });

    test('FileContent carries encoding + mimeType', () {
      const fc = FileContent(
        path: 'a.png',
        content: 'AAAA',
        size: 3,
        encoding: 'base64',
        mimeType: 'image/png',
      );
      expect(fc.encoding, 'base64');
      expect(fc.mimeType, 'image/png');
    });

    test('FileContent encoding defaults to utf8', () {
      const fc = FileContent(path: 'a.txt', content: 'hi', size: 2);
      expect(fc.encoding, 'utf8');
    });
  });

  group('Message classes', () {
    test('TreeFullMessage stores fields', () {
      final root = FileNode.fromJson({
        'name': 'root',
        'path': '',
        'type': 'directory',
      })!;
      final msg = TreeFullMessage(
        id: '1',
        timestamp: 1000,
        projectId: 'proj-1',
        root: root,
      );
      expect(msg.id, '1');
      expect(msg.timestamp, 1000);
      expect(msg.projectId, 'proj-1');
      expect(msg.root.name, 'root');
    });

    test('TreeUpdateMessage stores fields', () {
      final added = FileNode.fromJson({
        'name': 'new.ts',
        'path': 'src/new.ts',
        'type': 'file',
      })!;
      final msg = TreeUpdateMessage(
        id: '2',
        timestamp: 2000,
        projectId: 'proj-1',
        added: [added],
        modified: [],
        removed: ['old.ts'],
      );
      expect(msg.added, hasLength(1));
      expect(msg.removed, ['old.ts']);
    });

    test('FileContentMessage stores fields', () {
      const msg = FileContentMessage(
        id: '3',
        timestamp: 3000,
        projectId: 'proj-1',
        path: 'src/main.ts',
        content: 'console.log("hi")',
        size: 18,
      );
      expect(msg.path, 'src/main.ts');
      expect(msg.content, 'console.log("hi")');
      expect(msg.error, isNull);
    });
  });
}
