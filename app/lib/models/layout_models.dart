import 'package:flutter/material.dart';

import '../screens/terminal_screen.dart';
import '../screens/preview_screen.dart';
import '../screens/file_explorer_screen.dart';
import '../utils/platform_utils.dart';

enum LayoutPanelItem { terminals, previews, files }

enum BarPosition { auto, top, bottom }

extension BarPositionResolve on BarPosition {
  /// Resolve [auto] based on platform: desktop → top, mobile → bottom.
  BarPosition resolve() {
    if (this != BarPosition.auto) return this;
    return isMobilePlatform ? BarPosition.bottom : BarPosition.top;
  }
}

extension LayoutPanelItemUI on LayoutPanelItem {
  String get label => switch (this) {
    LayoutPanelItem.terminals => 'Terminals',
    LayoutPanelItem.previews => 'Preview',
    LayoutPanelItem.files => 'Files',
  };

  IconData get icon => switch (this) {
    LayoutPanelItem.terminals => Icons.terminal,
    LayoutPanelItem.previews => Icons.preview_outlined,
    LayoutPanelItem.files => Icons.folder_outlined,
  };

  Widget buildPanel() => switch (this) {
    LayoutPanelItem.terminals => const TerminalScreen(),
    LayoutPanelItem.previews => const PreviewScreen(),
    LayoutPanelItem.files => const FileExplorerScreen(),
  };
}

class LayoutConfig {
  final List<LayoutPanelItem>? left;
  final List<LayoutPanelItem>? right;
  final BarPosition commandBar;
  final BarPosition tabPosition;

  const LayoutConfig({
    this.left,
    this.right,
    this.commandBar = BarPosition.auto,
    this.tabPosition = BarPosition.auto,
  });

  static const defaultLayout = LayoutConfig();

  List<LayoutPanelItem> get effectiveLeft =>
      left ?? [LayoutPanelItem.terminals];

  List<LayoutPanelItem> get effectiveRight =>
      right ?? [LayoutPanelItem.previews, LayoutPanelItem.files];

  static LayoutConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;

    return LayoutConfig(
      left: _parsePanelItems(json['left']),
      right: _parsePanelItems(json['right']),
      commandBar: _parseBarPosition(json['commandBar']),
      tabPosition: _parseBarPosition(json['tabPosition']),
    );
  }

  static List<LayoutPanelItem>? _parsePanelItems(dynamic list) {
    if (list is! List) return null;
    final items = <LayoutPanelItem>[];
    for (final item in list) {
      if (item is String) {
        final parsed = switch (item) {
          'terminals' => LayoutPanelItem.terminals,
          'previews' => LayoutPanelItem.previews,
          'files' => LayoutPanelItem.files,
          _ => null,
        };
        if (parsed != null) items.add(parsed);
      }
    }
    return items.isEmpty ? null : items;
  }

  static BarPosition _parseBarPosition(dynamic value) {
    return switch (value) {
      'top' => BarPosition.top,
      'bottom' => BarPosition.bottom,
      _ => BarPosition.auto,
    };
  }

  LayoutConfig copyWith({
    List<LayoutPanelItem>? left,
    List<LayoutPanelItem>? right,
    BarPosition? commandBar,
    BarPosition? tabPosition,
  }) {
    return LayoutConfig(
      left: left ?? this.left,
      right: right ?? this.right,
      commandBar: commandBar ?? this.commandBar,
      tabPosition: tabPosition ?? this.tabPosition,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutConfig &&
          other.commandBar == commandBar &&
          other.tabPosition == tabPosition &&
          _listEquals(other.left, left) &&
          _listEquals(other.right, right);

  @override
  int get hashCode => Object.hash(
    commandBar,
    tabPosition,
    left != null ? Object.hashAll(left!) : null,
    right != null ? Object.hashAll(right!) : null,
  );

  static bool _listEquals(List<LayoutPanelItem>? a, List<LayoutPanelItem>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
