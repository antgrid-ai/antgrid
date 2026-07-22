import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/screens/preview_screen.dart';

void main() {
  Widget buildTestWidget({required AsyncValue<PreviewState> previewState}) {
    return ProviderScope(
      overrides: [
        previewStateProvider.overrideWith(
          (ref) => Stream.value(previewState.value ?? const PreviewState()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: PreviewScreen())),
    );
  }

  group('PreviewScreen', () {
    testWidgets('shows empty state when no ports detected', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows port list when ports available', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final state = PreviewState(
        ports: [
          const PortInfo(port: 3000, processName: 'node'),
          const PortInfo(port: 8080, label: 'vite'),
        ],
      );

      await tester.pumpWidget(buildTestWidget(previewState: AsyncData(state)));
      await tester.pump();

      expect(find.text('Port 3000'), findsOneWidget);
      expect(find.text('Port 8080'), findsOneWidget);
      expect(find.text('node'), findsOneWidget);
      expect(find.text('vite'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows loading when preview state is loading', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncLoading()),
      );

      expect(find.byType(AbLoading), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows empty state on Windows when no ports', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows empty state on Linux when no ports', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
