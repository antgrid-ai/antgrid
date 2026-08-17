import 'ab_message.dart' show GitFileStatusEntry;

enum FileNodeType { file, directory }

class FileNode {
  final String name;
  final String path;
  final FileNodeType type;
  final int? size;
  final String? extension;
  final List<FileNode> children;

  const FileNode({
    required this.name,
    required this.path,
    required this.type,
    this.size,
    this.extension,
    this.children = const [],
  });

  static FileNode? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final path = json['path'];
    final typeStr = json['type'];

    if (name is! String || path is! String || typeStr is! String) return null;

    final FileNodeType type;
    switch (typeStr) {
      case 'file':
        type = FileNodeType.file;
      case 'directory':
        type = FileNodeType.directory;
      default:
        return null;
    }

    final childrenJson = json['children'];
    final children = <FileNode>[];
    if (childrenJson is List) {
      for (final c in childrenJson) {
        if (c is Map<String, dynamic>) {
          final child = FileNode.fromJson(c);
          if (child != null) children.add(child);
        }
      }
    }

    // Sort: directories first, then alphabetical by name (case-insensitive)
    children.sort((a, b) {
      if (a.type == FileNodeType.directory &&
          b.type != FileNodeType.directory) {
        return -1;
      }
      if (a.type != FileNodeType.directory &&
          b.type == FileNodeType.directory) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return FileNode(
      name: name,
      path: path,
      type: type,
      size: json['size'] as int?,
      extension: json['extension'] as String?,
      children: children,
    );
  }
}

class FileContent {
  final String path;
  final String? content;
  final int size;
  final String? error;
  final String encoding; // 'utf8' | 'base64'
  final String? mimeType;

  const FileContent({
    required this.path,
    this.content,
    required this.size,
    this.error,
    this.encoding = 'utf8',
    this.mimeType,
  });
}

/// Per-tab right-pane state for the Files tab.
///
/// Mutated only by Files-tab actions (selectFile, clearViewingFile,
/// applyPreferences). Reading these fields from the Git tab is a leak.
class FilesPaneState {
  final String? selectedFilePath;
  final FileContent? viewingFile;
  final bool isLoading;
  final bool fileModifiedExternally;
  final int? searchLine;
  final String? searchQuery;

  const FilesPaneState({
    this.selectedFilePath,
    this.viewingFile,
    this.isLoading = false,
    this.fileModifiedExternally = false,
    this.searchLine,
    this.searchQuery,
  });

  static const empty = FilesPaneState();

  FilesPaneState copyWith({
    String? selectedFilePath,
    bool clearSelectedFilePath = false,
    FileContent? viewingFile,
    bool clearViewingFile = false,
    bool? isLoading,
    bool? fileModifiedExternally,
    int? searchLine,
    bool clearSearchLine = false,
    String? searchQuery,
    bool clearSearchQuery = false,
  }) {
    return FilesPaneState(
      selectedFilePath: clearSelectedFilePath
          ? null
          : (selectedFilePath ?? this.selectedFilePath),
      viewingFile: clearViewingFile ? null : (viewingFile ?? this.viewingFile),
      isLoading: isLoading ?? this.isLoading,
      fileModifiedExternally:
          fileModifiedExternally ?? this.fileModifiedExternally,
      searchLine: clearSearchLine ? null : (searchLine ?? this.searchLine),
      searchQuery: clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
    );
  }
}

/// Per-tab right-pane state for the Git tab.
///
/// Mutated only by Git-tab actions (requestDiff, clearDiff, gitViewFile,
/// gitClearViewing). Reading these fields from the Files tab is a leak.
///
/// [diffPath]/[diffContent]/[diffLoading] back the DiffViewer.
/// [viewingPath]/[viewingFile]/[viewingLoading] back the "View File from diff"
/// mode that renders a FileContentViewer inside the Git pane.
class GitPaneState {
  final String? diffPath;
  final String? diffContent;
  final int? diffAdditions;
  final int? diffDeletions;
  final bool diffLoading;
  final String? viewingPath;
  final FileContent? viewingFile;
  final bool viewingLoading;

  const GitPaneState({
    this.diffPath,
    this.diffContent,
    this.diffAdditions,
    this.diffDeletions,
    this.diffLoading = false,
    this.viewingPath,
    this.viewingFile,
    this.viewingLoading = false,
  });

  static const empty = GitPaneState();

  GitPaneState copyWith({
    String? diffPath,
    String? diffContent,
    int? diffAdditions,
    int? diffDeletions,
    bool? diffLoading,
    bool clearDiff = false,
    String? viewingPath,
    FileContent? viewingFile,
    bool? viewingLoading,
    bool clearViewing = false,
  }) {
    return GitPaneState(
      diffPath: clearDiff ? null : (diffPath ?? this.diffPath),
      diffContent: clearDiff ? null : (diffContent ?? this.diffContent),
      diffAdditions: clearDiff ? null : (diffAdditions ?? this.diffAdditions),
      diffDeletions: clearDiff ? null : (diffDeletions ?? this.diffDeletions),
      diffLoading: clearDiff ? false : (diffLoading ?? this.diffLoading),
      viewingPath: clearViewing ? null : (viewingPath ?? this.viewingPath),
      viewingFile: clearViewing ? null : (viewingFile ?? this.viewingFile),
      viewingLoading: clearViewing
          ? false
          : (viewingLoading ?? this.viewingLoading),
    );
  }
}

class FileTreeState {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? filterQuery;
  final String? projectId;
  final Map<String, String> gitFileStatuses; // path → M/A/D/R/U/! (deduped)
  /// Raw per-entry list (a path can appear twice — once staged, once
  /// unstaged) backing the Git tab's sectioned Staged/Changes/Merge view.
  final List<GitFileStatusEntry> gitFileEntries;
  final bool showChangedOnly;
  final FilesPaneState files;
  final GitPaneState git;

  /// Last git commit/discard result message. Paired with [gitOpFeedbackSeq]:
  /// it's a one-shot *event*, not durable state. The message string may repeat
  /// verbatim (two "Discarded changes"), so consumers (the toaster) de-dup on
  /// the monotonically-increasing seq, which makes every op a distinct event
  /// without anyone having to clear the message first.
  final String? gitOpFeedback;
  final int gitOpFeedbackSeq;

  const FileTreeState({
    this.root,
    this.expandedPaths = const {},
    this.filterQuery,
    this.projectId,
    this.gitFileStatuses = const {},
    this.gitFileEntries = const [],
    this.showChangedOnly = false,
    this.files = FilesPaneState.empty,
    this.git = GitPaneState.empty,
    this.gitOpFeedback,
    this.gitOpFeedbackSeq = 0,
  });

  FileTreeState copyWith({
    FileNode? root,
    Set<String>? expandedPaths,
    String? filterQuery,
    bool clearFilterQuery = false,
    String? projectId,
    Map<String, String>? gitFileStatuses,
    List<GitFileStatusEntry>? gitFileEntries,
    bool? showChangedOnly,
    FilesPaneState? files,
    GitPaneState? git,
    String? gitOpFeedback,
    int? gitOpFeedbackSeq,
  }) {
    return FileTreeState(
      root: root ?? this.root,
      expandedPaths: expandedPaths ?? this.expandedPaths,
      filterQuery: clearFilterQuery ? null : (filterQuery ?? this.filterQuery),
      projectId: projectId ?? this.projectId,
      gitFileStatuses: gitFileStatuses ?? this.gitFileStatuses,
      gitFileEntries: gitFileEntries ?? this.gitFileEntries,
      showChangedOnly: showChangedOnly ?? this.showChangedOnly,
      files: files ?? this.files,
      git: git ?? this.git,
      gitOpFeedback: gitOpFeedback ?? this.gitOpFeedback,
      gitOpFeedbackSeq: gitOpFeedbackSeq ?? this.gitOpFeedbackSeq,
    );
  }
}

// --- Message classes ---

class TreeFullMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final FileNode root;
  final int? seq;

  const TreeFullMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.root,
    this.seq,
  });
}

class TreeUpdateMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final List<FileNode> added;
  final List<FileNode> modified;
  final List<String> removed;
  final int? seq;

  const TreeUpdateMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    this.added = const [],
    this.modified = const [],
    this.removed = const [],
    this.seq,
  });
}

class FileContentMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String path;
  final String? content;
  final int size;
  final String? error;
  final String encoding; // 'utf8' | 'base64'
  final String? mimeType;

  const FileContentMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.path,
    this.content,
    required this.size,
    this.error,
    this.encoding = 'utf8',
    this.mimeType,
  });
}
