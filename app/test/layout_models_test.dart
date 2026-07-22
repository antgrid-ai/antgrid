import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/layout_models.dart';

void main() {
  group('LayoutConfig.fromJson', () {
    test('parses layout with all fields', () {
      final config = LayoutConfig.fromJson({
        'left': ['terminals'],
        'right': ['previews', 'files'],
        'commandBar': 'bottom',
        'tabPosition': 'top',
      });
      expect(config, isNotNull);
      expect(config!.left, [LayoutPanelItem.terminals]);
      expect(config.right, [LayoutPanelItem.previews, LayoutPanelItem.files]);
      expect(config.commandBar, BarPosition.bottom);
      expect(config.tabPosition, BarPosition.top);
    });

    test('parses empty layout', () {
      final config = LayoutConfig.fromJson({});
      expect(config, isNotNull);
      expect(config!.left, isNull);
      expect(config.right, isNull);
      expect(config.commandBar, BarPosition.auto);
    });

    test('returns null for null input', () {
      final config = LayoutConfig.fromJson(null);
      expect(config, isNull);
    });

    test('effectiveLeft returns defaults when not set', () {
      final config = LayoutConfig.fromJson({})!;
      expect(config.effectiveLeft, [LayoutPanelItem.terminals]);
    });

    test('effectiveRight returns defaults when not set', () {
      final config = LayoutConfig.fromJson({})!;
      expect(config.effectiveRight, [
        LayoutPanelItem.previews,
        LayoutPanelItem.files,
      ]);
    });

    test('ignores unknown panel items', () {
      final config = LayoutConfig.fromJson({
        'left': ['terminals', 'unknown'],
        'right': ['files'],
      });
      expect(config!.left, [LayoutPanelItem.terminals]);
      expect(config.right, [LayoutPanelItem.files]);
    });

    test('returns null for empty panel items list', () {
      final config = LayoutConfig.fromJson({
        'left': ['unknown'],
      });
      expect(config!.left, isNull);
    });

    test('commandBar defaults to auto', () {
      final config = LayoutConfig.fromJson({})!;
      expect(config.commandBar, BarPosition.auto);
    });

    test('tabPosition parses top', () {
      final config = LayoutConfig.fromJson({'tabPosition': 'top'})!;
      expect(config.tabPosition, BarPosition.top);
    });

    test('defaultLayout has auto positions', () {
      expect(LayoutConfig.defaultLayout.commandBar, BarPosition.auto);
      expect(LayoutConfig.defaultLayout.tabPosition, BarPosition.auto);
    });
  });
}
