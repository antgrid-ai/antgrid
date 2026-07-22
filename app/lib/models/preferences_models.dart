import 'package:flutter/foundation.dart';

class ProjectPreferences {
  final double splitRatio;
  final int workspaceViewIndex;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final bool showChangedOnly;
  final int panelMode; // 0=normal, 1=agentExpanded, 2=contextExpanded

  const ProjectPreferences({
    this.splitRatio = 0.5,
    this.workspaceViewIndex = 1,
    this.expandedPaths = const {},
    this.selectedFilePath,
    this.showChangedOnly = false,
    this.panelMode = 0,
  });

  ProjectPreferences copyWith({
    double? splitRatio,
    int? workspaceViewIndex,
    Set<String>? expandedPaths,
    String? selectedFilePath,
    bool clearSelectedFilePath = false,
    bool? showChangedOnly,
    int? panelMode,
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
    'panelMode': panelMode,
  };

  static ProjectPreferences fromJson(Map<String, dynamic> json) {
    // Backward compat: map old rightTabIndex to workspaceViewIndex
    final workspaceIdx =
        json['workspaceViewIndex'] as int? ??
        json['rightTabIndex'] as int? ??
        1;

    // Backward compat: map old bool fields to panelMode int
    int panelMode = json['panelMode'] as int? ?? 0;
    if (panelMode == 0 && !json.containsKey('panelMode')) {
      final agentExp = json['agentPanelExpanded'] as bool? ?? false;
      final ctxExp = json['contextPanelExpanded'] as bool? ?? false;
      if (agentExp && !ctxExp) {
        panelMode = 1;
      } else if (ctxExp && !agentExp) {
        panelMode = 2;
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
