import 'package:flutter/foundation.dart';

/// Machine key for THIS device's own bridge in every machine-keyed map the
/// project-first views read. Remote machines key by their bare device uuid; the
/// local one has no uuid it can rely on synchronously (the device record loads
/// asynchronously, and a fresh install has none), so it gets a fixed key.
const String kLocalMachineKey = 'local';

/// One project a machine was last seen holding, as its bridge advertised it.
///
/// Persisted so a project on a machine that is offline, or simply not dialed
/// this launch, still has a row: the live advert exists only while a socket is
/// open.
@immutable
class CatalogProject {
  const CatalogProject({
    required this.projectId,
    this.label,
    this.gitRemote,
    this.gitRemoteProbed = false,
  });

  final String projectId;
  final String? label;

  /// Normalized origin; meaningful only when [gitRemoteProbed]. See
  /// `AdvertisedProject.gitRemote`.
  final String? gitRemote;
  final bool gitRemoteProbed;

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    if (label != null) 'label': label,
    if (gitRemoteProbed) 'gitRemote': gitRemote,
  };

  static CatalogProject? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['projectId'];
    if (id is! String || id.isEmpty) return null;
    final label = raw['label'];
    final remote = raw['gitRemote'];
    return CatalogProject(
      projectId: id,
      label: label is String ? label : null,
      gitRemote: remote is String ? remote : null,
      gitRemoteProbed: raw.containsKey('gitRemote'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogProject &&
      other.projectId == projectId &&
      other.label == label &&
      other.gitRemote == gitRemote &&
      other.gitRemoteProbed == gitRemoteProbed;

  @override
  int get hashCode => Object.hash(projectId, label, gitRemote, gitRemoteProbed);
}
