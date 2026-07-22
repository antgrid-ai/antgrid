import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/image_viewer.dart';

// 1x1 transparent PNG
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  testWidgets('decodes base64 and shows an Image', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ImageViewer(
          content: const FileContent(
            path: 'a.png',
            content: _png,
            size: 70,
            encoding: 'base64',
            mimeType: 'image/png',
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('shows fallback on bad base64', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ImageViewer(
          content: const FileContent(
            path: 'a.png',
            content: '!!!not-base64!!!',
            size: 5,
            encoding: 'base64',
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining("Couldn't render"), findsOneWidget);
  });
}
