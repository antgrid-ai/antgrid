import 'package:flutter/foundation.dart';

@immutable
class GitBranchCatalog {
  final bool isRepository;
  final String? current;
  final List<String> branches;

  const GitBranchCatalog({
    required this.isRepository,
    required this.current,
    required this.branches,
  });

  factory GitBranchCatalog.fromJson(Map<String, dynamic> json) {
    final isRepo = json['isRepository'];
    if (isRepo is! bool) {
      throw const FormatException('Invalid or missing isRepository in GitBranchCatalog');
    }

    final currentVal = json['current'];
    if (currentVal != null && currentVal is! String) {
      throw const FormatException('Invalid current in GitBranchCatalog');
    }

    final branchesVal = json['branches'];
    if (branchesVal is! List) {
      throw const FormatException('Invalid or missing branches in GitBranchCatalog');
    }

    final branchesList = <String>[];
    for (final item in branchesVal) {
      if (item is! String) {
        throw const FormatException('Invalid branch entry in GitBranchCatalog');
      }
      branchesList.add(item);
    }

    return GitBranchCatalog(
      isRepository: isRepo,
      current: currentVal as String?,
      branches: List.unmodifiable(branchesList),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GitBranchCatalog &&
          runtimeType == other.runtimeType &&
          isRepository == other.isRepository &&
          current == other.current &&
          listEquals(branches, other.branches);

  @override
  int get hashCode => Object.hash(isRepository, current, Object.hashAll(branches));
}

@immutable
class NewSessionBranchSelection {
  final String targetId;
  final String branch;

  const NewSessionBranchSelection({
    required this.targetId,
    required this.branch,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NewSessionBranchSelection &&
          runtimeType == other.runtimeType &&
          targetId == other.targetId &&
          branch == other.branch;

  @override
  int get hashCode => Object.hash(targetId, branch);
}
