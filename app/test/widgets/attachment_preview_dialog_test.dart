import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:antgrid/widgets/attachment_preview_dialog.dart';
import 'package:antgrid/widgets/file_viewer_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _PreviewService implements FileService {
  final changes = StreamController<FileTreeState>.broadcast();
  @override
  FileTreeState currentState = const FileTreeState();
  @override
  Stream<FileTreeState> get stateStream => changes.stream;

  void emit(PreviewPaneState preview) {
    currentState = currentState.copyWith(preview: preview);
    changes.add(currentState);
  }

  @override
  void openPreview(String path, {String? displayName}) => emit(
    PreviewPaneState(path: path, displayName: displayName, isLoading: true),
  );

  @override
  void closePreview() => emit(PreviewPaneState.empty);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('preview follows its source service and closes that slot', (
    tester,
  ) async {
    final source = _PreviewService();
    final focused = _PreviewService();
    addTearDown(source.changes.close);
    addTearDown(focused.changes.close);
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileTreeStateProvider.overrideWith((ref) => focused.stateStream),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Builder(
            builder: (context) {
              launchContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final closed = showFilePreviewDialog(
      launchContext,
      source,
      path: '/output/source.png',
      displayName: 'source.png',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    FileViewerRouter viewer() => tester.widget(find.byType(FileViewerRouter));
    expect(viewer().selectedFilePath, 'source.png');
    expect(viewer().isLoading, isTrue);

    const content = FileContent(
      path: '/output/source.png',
      size: 0,
      error: 'Preview unavailable',
    );
    source.emit(
      const PreviewPaneState(
        path: '/output/source.png',
        displayName: 'source.png',
        content: content,
      ),
    );
    focused.openPreview('/other/unrelated.png');
    await tester.pump();
    expect(viewer().fileContent, same(content));
    expect(viewer().isLoading, isFalse);
    expect(viewer().selectedFilePath, 'source.png');

    viewer().onClose!();
    await tester.pumpAndSettle();
    await closed;
    expect(source.currentState.preview.isOpen, isFalse);
    expect(focused.currentState.preview.isOpen, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  group('title bar', () {
    Future<_PreviewService> open(
      WidgetTester tester, {
      required Size screen,
      required FileContent content,
      String? displayName,
    }) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _PreviewService();
      addTearDown(service.changes.close);
      late BuildContext launchContext;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildAbTheme(),
            home: Builder(
              builder: (context) {
                launchContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      unawaited(
        showFilePreviewDialog(
          launchContext,
          service,
          path: content.path,
          displayName: displayName ?? 'notes.json',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      service.emit(
        PreviewPaneState(
          path: content.path,
          displayName: displayName ?? 'notes.json',
          content: content,
        ),
      );
      await tester.pump();
      return service;
    }

    const content = FileContent(
      path: r'C:\Users\me\Docs\notes.json',
      content: '{}',
      size: 2048,
    );

    testWidgets('names the file, its type and size, and where it lives', (
      tester,
    ) async {
      await open(tester, screen: const Size(1400, 900), content: content);
      expect(find.text('notes.json'), findsOneWidget);
      expect(
        find.text(r'JSON · 2.0 KB · C:\Users\me\Docs'),
        findsOneWidget,
      );
      expect(find.byTooltip('Copy path'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves the viewer one header, not two', (tester) async {
      await open(tester, screen: const Size(1400, 900), content: content);
      expect(find.byTooltip('Close file'), findsNothing);
      expect(find.byTooltip('Download'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('fills a phone and caps a large window', (tester) async {
      await open(tester, screen: const Size(400, 800), content: content);
      Size dialog() => tester.getSize(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(dialog().width, 400 - 16);
      await tester.pumpWidget(const SizedBox());

      await open(tester, screen: const Size(2400, 1400), content: content);
      expect(dialog().width, 1120);
      expect(dialog().height, 900);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('previewFolder keeps the separator style the path was written in', () {
    expect(previewFolder(r'C:\a\b.txt'), r'C:\a');
    expect(previewFolder('/a/b/c.txt'), '/a/b');
    expect(previewFolder(r'C:\b.txt'), r'C:\');
    expect(previewFolder('b.txt'), '');
    expect(previewFileName(r'C:\a\b.txt'), 'b.txt');
  });

  test('previewKindLabel names what the viewer will show', () {
    String label(String path, {String enc = 'utf8', String? mime}) =>
        previewKindLabel(
          FileContent(path: path, size: 1, encoding: enc, mimeType: mime),
        );
    expect(label('/a/plan.md'), 'Markdown');
    expect(label('/a/x.dart'), 'DART');
    expect(label('/a/Makefile'), 'Text');
    expect(label('/a/x.pdf', enc: 'base64', mime: 'application/pdf'), 'PDF');
    expect(label('/a/x.png', enc: 'base64', mime: 'image/png'), 'Image');
  });
}
