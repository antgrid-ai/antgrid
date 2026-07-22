import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/pdf_viewer.dart';

void main() {
  testWidgets('shows fallback on bad base64', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePdfViewer(
          content: const FileContent(
            path: 'a.pdf',
            content: '!!!not-base64!!!',
            size: 5,
            encoding: 'base64',
            mimeType: 'application/pdf',
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('a.pdf'), findsOneWidget);
    expect(find.textContaining("Couldn't render"), findsOneWidget);
  });
}
