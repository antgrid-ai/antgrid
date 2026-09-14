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
}
