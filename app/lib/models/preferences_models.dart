import 'package:flutter/foundation.dart';

/// Legacy-ordinal targets for [ProjectPreferences.panelMode]. Keep in lockstep
/// with `_PanelMode` in `screens/workspace_shell.dart` — that enum's `.name` is
/// what gets written. A drift here only breaks migration of pre-name prefs, and
/// the shell resolves an unrecognized name to "unchosen", so the blast radius
/// is a lost legacy preference rather than a crash.
abstract final class _PanelModeNames {
  static const contextHidden = 'contextHidden';
  static const contextExpanded = 'contextExpanded';
}

class ProjectPreferences {
  final double splitRatio;
  final int workspaceViewIndex;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final bool showChangedOnly;
  /// Persisted `_PanelMode` NAME (`normal` / `contextHidden` /
  /// `contextExpanded`), or null when the user has never chosen — which is NOT
  /// the same as choosing `normal`: the shell derives a viewport-dependent
  /// default while this stays null (see
  /// `WorkspaceShellState._defaultPanelMode`), and any explicit toggle pins a
  /// concrete value that wins from then on.
  ///
  /// A name rather than the enum ordinal, so reordering `_PanelMode` can't
  /// silently reinterpret stored preferences — the failure mode
  /// [workspaceViewIndex] has already shipped once (see the NOTE in
  /// `WorkspaceShellState._applyPrefs`).
  final String? panelMode;

  const ProjectPreferences({
    this.splitRatio = 0.5,
    this.workspaceViewIndex = 1,
    this.expandedPaths = const {},
    this.selectedFilePath,
    this.showChangedOnly = false,
    this.panelMode,
  });

  ProjectPreferences copyWith({
    double? splitRatio,
    int? workspaceViewIndex,
    Set<String>? expandedPaths,
    String? selectedFilePath,
    bool clearSelectedFilePath = false,
    bool? showChangedOnly,
    String? panelMode,
  }) {
    return ProjectPreferences(
      splitRatio: splitRatio ?? this.splitRatio,
      workspaceViewIndex: workspaceViewIndex ?? this.workspaceViewIndex,
      expandedPaths: expandedPaths ?? this.expandedPaths,
      selectedFilePath: clearSelectedFilePath
          ? null
          : (selectedFilePath ?? this.selectedFilePath),
      showChangedOnly: showChangedOnly ?? this.showChangedOnly,
      panelMode: panelMode ?? this.panelMode,
    );
  }

  Map<String, dynamic> toJson() => {
    'splitRatio': splitRatio,
    'workspaceViewIndex': workspaceViewIndex,
    'expandedPaths': expandedPaths.toList(),
    if (selectedFilePath != null) 'selectedFilePath': selectedFilePath,
    'showChangedOnly': showChangedOnly,
    // Omitted while unchosen so a reload still reads null and re-derives the
    // viewport default, rather than freezing whatever this device resolved.
    if (panelMode != null) 'panelMode': panelMode,
  };

  static ProjectPreferences fromJson(Map<String, dynamic> json) {
    // Backward compat: map old rightTabIndex to workspaceViewIndex
    final workspaceIdx =
        json['workspaceViewIndex'] as int? ??
        json['rightTabIndex'] as int? ??
        1;

    // panelMode moved from enum ordinal to enum name. A legacy 1 or 2 was only
    // ever reachable by an explicit user toggle, so it maps to a real choice.
    // A legacy 0 is ambiguous and must NOT: the previous toJson wrote the key
    // unconditionally, so every project ever opened has one on disk, and
    // honouring it would suppress the viewport default for every existing
    // install. Same reasoning for both legacy bools reading false.
    String? panelMode = switch (json['panelMode']) {
      String s => s,
      1 => _PanelModeNames.contextHidden,
      2 => _PanelModeNames.contextExpanded,
      _ => null,
    };
    if (panelMode == null) {
      final agentExp = json['agentPanelExpanded'] as bool? ?? false;
      final ctxExp = json['contextPanelExpanded'] as bool? ?? false;
      if (agentExp && !ctxExp) {
        panelMode = _PanelModeNames.contextHidden;
      } else if (ctxExp && !agentExp) {
        panelMode = _PanelModeNames.contextExpanded;
      }
    }

    return ProjectPreferences(
      splitRatio: (json['splitRatio'] as num?)?.toDouble() ?? 0.5,
      workspaceViewIndex: workspaceIdx,
      expandedPaths: json['expandedPaths'] is List
          ? (json['expandedPaths'] as List).whereType<String>().toSet()
          : const {},
      selectedFilePath: json['selectedFilePath'] as String?,
      showChangedOnly: json['showChangedOnly'] as bool? ?? false,
      panelMode: panelMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectPreferences &&
          other.splitRatio == splitRatio &&
          other.workspaceViewIndex == workspaceViewIndex &&
          other.selectedFilePath == selectedFilePath &&
          other.showChangedOnly == showChangedOnly &&
          other.panelMode == panelMode &&
          setEquals(other.expandedPaths, expandedPaths);

  @override
  int get hashCode => Object.hash(
    splitRatio,
    workspaceViewIndex,
    selectedFilePath,
    showChangedOnly,
    panelMode,
    Object.hashAllUnordered(expandedPaths),
  );
}
