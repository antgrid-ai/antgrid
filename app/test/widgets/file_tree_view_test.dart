import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/carbon_empty_state.dart';
import 'package:antgrid/widgets/file_tree_view.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/clipboard.dart';
import '../helpers/counting_file_node.dart';

/// The rendered color of the row's name label — reads the actual [Text]
/// style rather than inspecting [FileNode.ignored] directly, since the
/// dimming this pins lives entirely in how the widget renders that flag.
Color _labelColor(WidgetTester tester, String name) =>
    tester.widget<Text>(find.text(name)).style!.color!;

CarbonColors _colors(WidgetTester tester) =>
    CarbonTheme.of(tester.element(find.byType(FileTreeView))).colors;

void main() {
  FileNode makeTree() {
    return const FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'lib',
          path: 'project/lib',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'main.dart',
              path: 'project/lib/main.dart',
              type: FileNodeType.file,
              extension: 'dart',
            ),
            FileNode(
              name: 'utils.dart',
              path: 'project/lib/utils.dart',
              type: FileNodeType.file,
              extension: 'dart',
            ),
          ],
        ),
        FileNode(
          name: 'README.md',
          path: 'project/README.md',
          type: FileNodeType.file,
          extension: 'md',
        ),
      ],
    );
  }

  Widget host(
    Widget tree, {
    double textScale = 1,
    Brightness brightness = Brightness.dark,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: AbCarbonScope(child: tree)),
  );

  Widget buildTestWidget({
    FileNode? root,
    Set<String> expandedPaths = const {},
    String? selectedFilePath,
    String? revealedDirectoryPath,
    void Function(String)? onToggleExpanded,
    void Function(String)? onFileSelected,
    double textScale = 1,
  }) => host(
    FileTreeView(
      root: root,
      expandedPaths: expandedPaths,
      selectedFilePath: selectedFilePath,
      revealedDirectoryPath: revealedDirectoryPath,
      onToggleExpanded: onToggleExpanded ?? (_) {},
      onFileSelected: onFileSelected ?? (_) {},
    ),
    textScale: textScale,
  );

  void smallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('FileTreeView', () {
    testWidgets('shows empty state when root is null', (tester) async {
      await tester.pumpWidget(buildTestWidget(root: null));

      expect(find.byType(CarbonEmptyState), findsOneWidget);
      expect(find.text('No files available'), findsOneWidget);
    });

    testWidgets('renders directory and file names', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(buildTestWidget(root: tree));

      // Root children: lib directory and README.md
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('tapping a directory calls onToggleExpanded', (tester) async {
      final tree = makeTree();
      String? tappedPath;

      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          onToggleExpanded: (path) => tappedPath = path,
        ),
      );

      await tester.tap(find.text('lib'));
      expect(tappedPath, 'project/lib');
    });

    group('Copy path', () {
      Widget themed() => buildTestWidget(
        root: makeTree(),
        expandedPaths: const {'project/lib'},
      );

      testWidgets('right-click copies the project-relative path', (
        tester,
      ) async {
        final copied = captureClipboard(tester);
        await tester.pumpWidget(themed());

        final click = await tester.startGesture(
          tester.getCenter(find.text('main.dart')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await click.up();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy path'));
        await tester.pumpAndSettle();

        expect(copied, ['project/lib/main.dart']);
      });

      testWidgets('long-press offers it on touch, for folders too', (
        tester,
      ) async {
        final copied = captureClipboard(tester);
        await tester.pumpWidget(themed());

        await tester.longPress(find.text('lib'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy path'));
        await tester.pumpAndSettle();

        expect(copied, ['project/lib']);
      });

      testWidgets('a right-click opens the menu without selecting the row', (
        tester,
      ) async {
        String? selected;
        await tester.pumpWidget(
          buildTestWidget(
            root: makeTree(),
            onFileSelected: (path) => selected = path,
          ),
        );

        final click = await tester.startGesture(
          tester.getCenter(find.text('README.md')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await click.up();
        await tester.pumpAndSettle();

        expect(find.text('Copy path'), findsOneWidget);
        expect(selected, isNull);
      });
    });

    testWidgets('tapping a file calls onFileSelected', (tester) async {
      final tree = makeTree();
      String? selectedPath;

      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          onFileSelected: (path) => selectedPath = path,
        ),
      );

      await tester.tap(find.text('README.md'));
      expect(selectedPath, 'project/README.md');
    });

    testWidgets('arrow keys walk the rows from a single focus stop', (
      tester,
    ) async {
      final toggled = <String>[];
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          onToggleExpanded: toggled.add,
          onFileSelected: (_) {},
        ),
      );

      await tester.tap(find.text('README.md'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(toggled, ['project/lib']);
    });

    testWidgets('collapsed directory hides its children', (tester) async {
      final tree = makeTree();
      // lib is NOT in expandedPaths, so children should be hidden
      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);
      expect(find.text('utils.dart'), findsNothing);
    });

    testWidgets('expanded directory shows its children', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(root: tree, expandedPaths: {'project/lib'}),
      );

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('utils.dart'), findsOneWidget);
    });

    testWidgets('an empty directory (root with no children) says so', (
      tester,
    ) async {
      // Distinct from `root: null` above: this is a real, loaded listing
      // that came back empty, not "nothing has arrived yet". Name filtering
      // moved out of this widget (see file_explorer_screen.dart's
      // _FileFilterResults) — a bridge-backed `file:find`, not a local
      // substring pass over whatever this tree has loaded — so this is the
      // only way this empty state is reached now.
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [],
      );
      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(find.text('This folder is empty'), findsOneWidget);
    });

    testWidgets('a file and a folder sharing a path each keep a row', (
      tester,
    ) async {
      // Replacing a file with a directory of the same name leaves a deletion
      // and an addition that share the path; the row id carries the type.
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name: 'twin',
            path: 'project/twin',
            type: FileNodeType.directory,
          ),
          FileNode(name: 'twin', path: 'project/twin', type: FileNodeType.file),
        ],
      );
      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(tester.takeException(), isNull);
      expect(find.text('twin'), findsNWidgets(2));
    });

    testWidgets(
      'selecting a file off the current viewport scrolls to reveal it',
      (tester) async {
        smallView(tester);

        final tree = FileNode(
          name: 'project',
          path: 'project',
          type: FileNodeType.directory,
          children: [
            for (var i = 0; i < 60; i++)
              FileNode(
                name: 'file$i.dart',
                path: 'project/file$i.dart',
                type: FileNodeType.file,
                extension: 'dart',
              ),
          ],
        );

        // Nothing selected yet: the tree renders from the top, so a file far
        // down the (unscrolled) list is not yet built.
        await tester.pumpWidget(buildTestWidget(root: tree));
        expect(find.text('file59.dart'), findsNothing);

        // Selecting it (as opening it from an agent transcript link does)
        // should scroll the tree down to reveal its row, not just open the
        // file's content off in another pane.
        await tester.pumpWidget(
          buildTestWidget(root: tree, selectedFilePath: 'project/file59.dart'),
        );
        await tester.pumpAndSettle();

        expect(find.text('file59.dart'), findsOneWidget);
      },
    );

    group('reveal', () {
      FileNode longTree({bool deepLoaded = true}) => FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          for (var i = 0; i < 60; i++)
            FileNode(
              name: 'file$i.dart',
              path: 'project/file$i.dart',
              type: FileNodeType.file,
              extension: 'dart',
            ),
          FileNode(
            name: 'zdeep',
            path: 'project/zdeep',
            type: FileNodeType.directory,
            childrenLoaded: deepLoaded,
            children: deepLoaded
                ? const [
                    FileNode(
                      name: 'target.dart',
                      path: 'project/zdeep/target.dart',
                      type: FileNodeType.file,
                      extension: 'dart',
                    ),
                  ]
                : const [],
          ),
        ],
      );

      Widget themed({
        required FileNode root,
        Set<String> expandedPaths = const {'project/zdeep'},
        String? selectedFilePath,
        String? revealedDirectoryPath,
        double textScale = 1,
      }) => buildTestWidget(
        root: root,
        expandedPaths: expandedPaths,
        selectedFilePath: selectedFilePath,
        revealedDirectoryPath: revealedDirectoryPath,
        textScale: textScale,
      );

      testWidgets(
        'a revealed folder off the viewport is scrolled to and marked',
        (tester) async {
          smallView(tester);
          await tester.pumpWidget(themed(root: longTree()));
          expect(find.text('zdeep'), findsNothing);

          await tester.pumpWidget(
            themed(
              root: longTree(),
              selectedFilePath: 'project/file0.dart',
              revealedDirectoryPath: 'project/zdeep',
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('zdeep'), findsOneWidget);
          // Marked as the current row: selection takes the primary text colour
          // every other row at rest does not have.
          expect(_labelColor(tester, 'zdeep'), _colors(tester).textPrimary);
        },
      );

      testWidgets(
        'a target whose row loads after it was selected is still scrolled to',
        (tester) async {
          smallView(tester);
          await tester.pumpWidget(themed(root: longTree(deepLoaded: false)));

          // The link selects the file while its folder's children are still in
          // flight, so on this frame there is no row to scroll to.
          await tester.pumpWidget(
            themed(
              root: longTree(deepLoaded: false),
              selectedFilePath: 'project/zdeep/target.dart',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('target.dart'), findsNothing);

          await tester.pumpWidget(
            themed(
              root: longTree(),
              selectedFilePath: 'project/zdeep/target.dart',
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('target.dart'), findsOneWidget);
        },
      );

      testWidgets('a tree built with its target already set scrolls to it', (
        tester,
      ) async {
        smallView(tester);
        // A link that switches to the Files tab builds the tree fresh, with
        // the selection already in place: there is no change to react to.
        await tester.pumpWidget(
          themed(
            root: longTree(),
            selectedFilePath: 'project/zdeep/target.dart',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('target.dart'), findsOneWidget);
      });

      // Every row is one extent tall, so the offset is index * extent and the
      // row must land centred in the viewport to the pixel — at a large text
      // scale as much as at 1.0, where the extent grows with the label.
      for (final scale in [1.0, 2.0]) {
        testWidgets('lands exactly on the row at text scale $scale', (
          tester,
        ) async {
          smallView(tester);
          await tester.pumpWidget(themed(root: longTree(), textScale: scale));
          final extent = CarbonTreeView.rowExtentOf(
            tester.element(find.byType(CarbonTreeView)),
          );

          await tester.pumpWidget(
            themed(
              root: longTree(),
              selectedFilePath: 'project/file40.dart',
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();

          final position = tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position;
          expect(
            position.pixels,
            closeTo(40 * extent + extent / 2 - position.viewportDimension / 2, 0.01),
          );
          final viewport = tester.getRect(find.byType(CarbonTreeView));
          expect(
            tester.getCenter(find.text('file40.dart')).dy,
            closeTo(viewport.center.dy, 0.5),
          );
        });
      }
    });

    testWidgets('a filename wider than the panel does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(220, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name:
                'a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
            path:
                'project/a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
            type: FileNodeType.file,
            extension: 'dart',
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(tester.takeException(), isNull);
    });
  });

  group('ignored rows', () {
    testWidgets(
      'an ignored node renders dimmer than a normal sibling',
      (tester) async {
        const tree = FileNode(
          name: 'project',
          path: 'project',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'kept.dart',
              path: 'project/kept.dart',
              type: FileNodeType.file,
            ),
            FileNode(
              name: 'build.log',
              path: 'project/build.log',
              // Present only because includeIgnored asked for it.
              ignored: true,
              type: FileNodeType.file,
            ),
          ],
        );
        await tester.pumpWidget(buildTestWidget(root: tree));

        final colors = _colors(tester);
        expect(_labelColor(tester, 'build.log'), colors.textPlaceholder);
        expect(_labelColor(tester, 'kept.dart'), colors.textSecondary);
      },
    );

    // Asserted positively on both rows: an `isNot(dim)` on the sibling would
    // hold even if the ignored arm were never reached for a directory at all.
    testWidgets('an ignored directory dims below an ordinary one', (
      tester,
    ) async {
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name: 'lib',
            path: 'project/lib',
            type: FileNodeType.directory,
          ),
          FileNode(
            name: 'build',
            path: 'project/build',
            ignored: true,
            type: FileNodeType.directory,
          ),
        ],
      );
      await tester.pumpWidget(buildTestWidget(root: tree));

      final colors = _colors(tester);
      expect(_labelColor(tester, 'build'), colors.textPlaceholder);
      expect(_labelColor(tester, 'lib'), colors.textSecondary);
    });

    // Selection outranks the dim. Swapping the two arms of the ternary leaves
    // every other assertion in this group green while a selected ignored row
    // silently stops reading as selected.
    testWidgets('a selected ignored row still reads as selected', (
      tester,
    ) async {
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name: 'build.log',
            path: 'project/build.log',
            ignored: true,
            type: FileNodeType.file,
          ),
        ],
      );
      await tester.pumpWidget(
        buildTestWidget(root: tree, selectedFilePath: 'project/build.log'),
      );

      expect(_labelColor(tester, 'build.log'), _colors(tester).textPrimary);
    });
  });

  group('truncation notice', () {
    const cutDirectory = FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'lib',
          path: 'project/lib',
          type: FileNodeType.directory,
          truncated: true,
          children: [
            FileNode(
              name: 'main.dart',
              path: 'project/lib/main.dart',
              type: FileNodeType.file,
            ),
          ],
        ),
      ],
    );

    testWidgets('an expanded cut directory carries a notice', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: cutDirectory,
          expandedPaths: const {'project/lib'},
        ),
      );

      expect(find.text('more items not shown'), findsOneWidget);
    });

    testWidgets('a folded cut directory carries none', (tester) async {
      await tester.pumpWidget(buildTestWidget(root: cutDirectory));

      expect(find.text('more items not shown'), findsNothing);
    });

    // The root is the directory the node budget cuts first on a wide repo, and
    // it is the one with no row of its own to hang the notice off.
    testWidgets('a cut root carries a notice', (tester) async {
      const root = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        truncated: true,
        children: [
          FileNode(
            name: 'README.md',
            path: 'project/README.md',
            type: FileNodeType.file,
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(root: root));

      expect(find.text('more items not shown'), findsOneWidget);
    });

    testWidgets('a complete tree carries none', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(root: makeTree(), expandedPaths: const {'project/lib'}),
      );

      expect(find.text('more items not shown'), findsNothing);
    });

    testWidgets('a notice is not a row anyone can open', (tester) async {
      final toggled = <String>[];
      final selected = <String>[];
      await tester.pumpWidget(
        buildTestWidget(
          root: cutDirectory,
          expandedPaths: const {'project/lib'},
          onToggleExpanded: toggled.add,
          onFileSelected: selected.add,
        ),
      );

      await tester.tap(find.text('more items not shown'));
      await tester.pump();

      expect(toggled, isEmpty);
      expect(selected, isEmpty);
    });

    testWidgets(
      'a truncated directory still carries its notice beside a loading one',
      (tester) async {
        // Two directories, one cut and one still fetching — the loading row
        // must not crowd out or get confused with the truncation row.
        const tree = FileNode(
          name: 'project',
          path: 'project',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'lib',
              path: 'project/lib',
              type: FileNodeType.directory,
              truncated: true,
              children: [
                FileNode(
                  name: 'main.dart',
                  path: 'project/lib/main.dart',
                  type: FileNodeType.file,
                ),
              ],
            ),
            FileNode(
              name: 'src',
              path: 'project/src',
              type: FileNodeType.directory,
              childrenLoaded: false,
              childrenLoading: true,
            ),
          ],
        );

        await tester.pumpWidget(
          buildTestWidget(
            root: tree,
            expandedPaths: const {'project/lib', 'project/src'},
          ),
        );

        expect(find.text('more items not shown'), findsOneWidget);
        expect(find.text('Loading…'), findsOneWidget);
      },
    );

    // The reveal jumps to an off-screen row by multiplying ONE row extent by a
    // flat index, so a notice or loading row that rendered at any other height
    // would put every row below it out by the difference. The rows of a tree
    // share one fixed extent, so consecutive row centres are exactly that far
    // apart whatever each row holds.
    for (final scale in [1.0, 2.0]) {
      testWidgets('every row kind is one extent tall at text scale $scale', (
        tester,
      ) async {
        const tree = FileNode(
          name: 'project',
          path: 'project',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'lib',
              path: 'project/lib',
              type: FileNodeType.directory,
              truncated: true,
              children: [
                FileNode(
                  name: 'main.dart',
                  path: 'project/lib/main.dart',
                  type: FileNodeType.file,
                ),
              ],
            ),
            FileNode(
              name: 'src',
              path: 'project/src',
              type: FileNodeType.directory,
              childrenLoaded: false,
              childrenLoading: true,
            ),
          ],
        );

        await tester.pumpWidget(
          buildTestWidget(
            root: tree,
            expandedPaths: const {'project/lib', 'project/src'},
            textScale: scale,
          ),
        );

        final extent = CarbonTreeView.rowExtentOf(
          tester.element(find.byType(CarbonTreeView)),
        );
        final centres = [
          for (final label in [
            'lib',
            'main.dart',
            'more items not shown',
            'src',
            'Loading…',
          ])
            tester.getCenter(find.text(label)).dy,
        ];
        for (var i = 1; i < centres.length; i++) {
          expect(centres[i] - centres[i - 1], closeTo(extent, 0.01));
        }
      });
    }
  });

  group('loading notice', () {
    const expandingDirectory = FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'lib',
          path: 'project/lib',
          type: FileNodeType.directory,
          childrenLoaded: false,
          childrenLoading: true,
        ),
      ],
    );

    testWidgets(
      'an expanded directory with a request in flight and no children shows a loading row',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            root: expandingDirectory,
            expandedPaths: const {'project/lib'},
          ),
        );

        expect(find.text('Loading…'), findsOneWidget);
      },
    );

    testWidgets('a collapsed loading directory carries no loading row', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestWidget(root: expandingDirectory));

      expect(find.text('Loading…'), findsNothing);
    });

    testWidgets(
      'stale children stay on screen instead of being replaced by a loading row',
      (tester) async {
        // A collapse-then-re-expand re-requests even an already-loaded
        // directory — while that round trip is in flight the OLD
        // children keep rendering rather than being cleared for it.
        const staleWhileRefetching = FileNode(
          name: 'project',
          path: 'project',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'lib',
              path: 'project/lib',
              type: FileNodeType.directory,
              childrenLoading: true,
              children: [
                FileNode(
                  name: 'main.dart',
                  path: 'project/lib/main.dart',
                  type: FileNodeType.file,
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          buildTestWidget(
            root: staleWhileRefetching,
            expandedPaths: const {'project/lib'},
          ),
        );

        expect(find.text('main.dart'), findsOneWidget);
        expect(find.text('Loading…'), findsNothing);
      },
    );
  });

  group('FileTreeView reuse across rebuilds', () {
    testWidgets('an unchanged file tree is not re-walked on rebuild', (
      tester,
    ) async {
      final root = CountingFileNode(
        'project',
        type: FileNodeType.directory,
        children: makeTree().children,
      );
      final expanded = {'project/lib'};
      await tester.pumpWidget(
        buildTestWidget(root: root, expandedPaths: expanded),
      );
      final reads = root.childrenReads;
      expect(reads, greaterThan(0));

      await tester.pumpWidget(
        buildTestWidget(root: root, expandedPaths: expanded),
      );

      expect(root.childrenReads, reads);
      expect(find.text('main.dart'), findsOneWidget);
    });

    testWidgets('a replaced expanded set is walked again', (tester) async {
      final root = makeTree();
      await tester.pumpWidget(buildTestWidget(root: root));
      expect(find.text('main.dart'), findsNothing);

      await tester.pumpWidget(
        buildTestWidget(root: root, expandedPaths: {'project/lib'}),
      );
      expect(find.text('main.dart'), findsOneWidget);
    });
  });

  group('Carbon scope', () {
    testWidgets('no Ab widget sits under the scope in any row kind', (
      tester,
    ) async {
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        truncated: true,
        children: [
          FileNode(
            name: 'lib',
            path: 'project/lib',
            type: FileNodeType.directory,
            children: [
              FileNode(
                name: 'main.dart',
                path: 'project/lib/main.dart',
                type: FileNodeType.file,
              ),
            ],
          ),
          FileNode(
            name: 'src',
            path: 'project/src',
            type: FileNodeType.directory,
            childrenLoaded: false,
            childrenLoading: true,
          ),
        ],
      );
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: const {'project/lib', 'project/src'},
        ),
      );

      expect(abWidgetsInScope(tester), isEmpty);
    });
  });

  // Deep siblings with a shared prefix ellipsize to identical rows in a
  // narrow pane; only a cut name offers its full self on hover.
  testWidgets('a truncated name carries a tooltip and a whole one does not', (
    tester,
  ) async {
    const tree = FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'drawable-night-xxxhdpi-v31-landscape',
          path: 'project/drawable-night-xxxhdpi-v31-landscape',
          type: FileNodeType.directory,
        ),
        FileNode(name: 'a.md', path: 'project/a.md', type: FileNodeType.file),
      ],
    );
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 160,
          child: FileTreeView(
            root: tree,
            expandedPaths: const {},
            onToggleExpanded: (_) {},
            onFileSelected: (_) {},
          ),
        ),
      ),
    );

    CarbonTooltip tooltipFor(String name) => tester.widget<CarbonTooltip>(
      find
          .ancestor(of: find.text(name), matching: find.byType(CarbonTooltip))
          .first,
    );
    expect(tooltipFor('drawable-night-xxxhdpi-v31-landscape').enabled, isTrue);
    expect(
      tooltipFor('drawable-night-xxxhdpi-v31-landscape').message,
      'drawable-night-xxxhdpi-v31-landscape',
    );
    expect(tooltipFor('a.md').enabled, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
