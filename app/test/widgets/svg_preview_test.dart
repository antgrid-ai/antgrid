import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/svg_preview.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="red"/></svg>';

void main() {
  testWidgets('renders an SvgPicture in preview mode', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SvgPreview(
              content: const FileContent(
                path: 'a.svg',
                content: _svg,
                size: 80,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('svg-content')), findsOneWidget);
  });
}
