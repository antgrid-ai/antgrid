import 'ab_message.dart'
    show GitFileStatusEntry, GitLogEntry, GitCommitFileEntry;
import 'git_sync_state.dart';

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

/// The History tab's commit list plus whatever per-commit file lists the user
/// has expanded. A `Set`, not a single "open commit" — the History tab lets
/// more than one commit's file list stay expanded at once (unlike an
/// accordion), and [collapseAll] (an empty [expandedShas]) is the explicit
/// action that folds all of them back up.
class GitHistoryState {
  final List<GitLogEntry> commits;

  /// True only while fetching the NEXT page (scroll-triggered); the first
  /// page's own fetch is [initialLoad], since the list is empty either way and
  /// the two need different placeholders (a full-pane spinner vs. a trailing
  /// row).
  final bool loadingMore;
  final bool initialLoad;
  final bool hasMore;
  final String? error;

  /// Commits whose file list is expanded and showing.
  final Set<String> expandedShas;

  /// Per-commit file lists, once fetched — absent means "never requested",
  /// distinct from an empty list (a commit with a message but no diff, e.g. an
  /// empty merge commit).
  final Map<String, List<GitCommitFileEntry>> filesBySha;
  final Set<String> filesLoadingShas;
  final Map<String, String> filesErrorBySha;

  const GitHistoryState({
    this.commits = const [],
    this.loadingMore = false,
    this.initialLoad = true,
    this.hasMore = true,
    this.error,
    this.expandedShas = const {},
    this.filesBySha = const {},
    this.filesLoadingShas = const {},
    this.filesErrorBySha = const {},
  });

  static const empty = GitHistoryState();

  GitHistoryState copyWith({
    List<GitLogEntry>? commits,
    bool? loadingMore,
    bool? initialLoad,
    bool? hasMore,
    String? error,
    bool clearError = false,
    Set<String>? expandedShas,
    Map<String, List<GitCommitFileEntry>>? filesBySha,
    Set<String>? filesLoadingShas,
    Map<String, String>? filesErrorBySha,
  }) {
    return GitHistoryState(
      commits: commits ?? this.commits,
      loadingMore: loadingMore ?? this.loadingMore,
      initialLoad: initialLoad ?? this.initialLoad,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      expandedShas: expandedShas ?? this.expandedShas,
      filesBySha: filesBySha ?? this.filesBySha,
      filesLoadingShas: filesLoadingShas ?? this.filesLoadingShas,
      filesErrorBySha: filesErrorBySha ?? this.filesErrorBySha,
    );
  }
}

/// Per-tab right-pane state for the Git tab.
///
/// Mutated only by Git-tab actions (requestDiff, clearDiff, gitViewFile,
/// gitClearViewing). Reading these fields from the Files tab is a leak.
///
/// [diffPath]/[diffContent]/[diffLoading] back the DiffViewer — for a working
/// -tree diff when [diffCommitSha] is null, or for that commit's diff of
/// [diffPath] when it is set. One shared slot rather than a second copy under
/// [GitHistoryState]: only one diff is ever open regardless of which tab it
/// was opened from, and the viewer itself renders the same either way.
/// [viewingPath]/[viewingFile]/[viewingLoading] back the "View File from diff"
/// mode that renders a FileContentViewer inside the Git pane.
class GitPaneState {
  final String? diffPath;
  final String? diffContent;
  final int? diffAdditions;
  final int? diffDeletions;
  final bool diffLoading;

  /// Set when [diffPath] names a file WITHIN this commit rather than the
  /// working tree — the History tab's file list opens a diff the same way the
  /// Changes tab does, just scoped to a commit instead of HEAD.
  final String? diffCommitSha;

  final String? viewingPath;
  final FileContent? viewingFile;
  final bool viewingLoading;

  /// The History tab's own state — commit list, pagination, and expanded
  /// per-commit file lists. See [GitHistoryState].
  final GitHistoryState history;

  /// Folders the user has collapsed in the changed-files tree.
  ///
  /// COLLAPSED, not expanded — the inverse of `FileTreeState.expandedPaths` —
  /// because the Git tab's default is "show me everything that changed" and an
  /// expanded-set default of empty would open on a list of shut folders. It is
  /// also deliberately not the Files tab's set: the two tabs answer different
  /// questions about the same paths, and collapsing a folder to get a long
  /// change list under control must not fold away the file the Explorer is
  /// sitting on.
  final Set<String> collapsedPaths;

  /// How the branch stands against its upstream. Replayed on reconnect (it is
  /// in `kCheckoutDurableReplayTypes`), so this is durable state rather than a
  /// one-shot — an app that reconnects must not show a synced branch until the
  /// next op.
  final GitSyncState sync;

  /// The op currently in flight, if any. Null is idle; the two buttons are
  /// disabled together while either runs, since both mutate the same branch.
  final GitSyncOp? syncing;

  /// The last push/pull that failed, kept until the next sync attempt so the
  /// panel can offer the agent handoff after the toast has gone.
  final GitSyncFailure? lastSyncFailure;

  const GitPaneState({
    this.diffPath,
    this.diffContent,
    this.diffAdditions,
    this.diffDeletions,
    this.diffLoading = false,
    this.diffCommitSha,
    this.viewingPath,
    this.viewingFile,
    this.viewingLoading = false,
    this.collapsedPaths = const {},
    this.sync = GitSyncState.empty,
    this.syncing,
    this.lastSyncFailure,
    this.history = GitHistoryState.empty,
  });

  static const empty = GitPaneState();

  GitPaneState copyWith({
    String? diffPath,
    String? diffContent,
    int? diffAdditions,
    int? diffDeletions,
    bool? diffLoading,
    String? diffCommitSha,
    bool clearDiffCommitSha = false,
    bool clearDiff = false,
    String? viewingPath,
    FileContent? viewingFile,
    bool? viewingLoading,
    bool clearViewing = false,
    Set<String>? collapsedPaths,
    GitSyncState? sync,
    GitSyncOp? syncing,
    bool clearSyncing = false,
    GitSyncFailure? lastSyncFailure,
    bool clearSyncFailure = false,
    GitHistoryState? history,
  }) {
    return GitPaneState(
      diffPath: clearDiff ? null : (diffPath ?? this.diffPath),
      diffContent: clearDiff ? null : (diffContent ?? this.diffContent),
      diffAdditions: clearDiff ? null : (diffAdditions ?? this.diffAdditions),
      diffDeletions: clearDiff ? null : (diffDeletions ?? this.diffDeletions),
      diffLoading: clearDiff ? false : (diffLoading ?? this.diffLoading),
      diffCommitSha: (clearDiff || clearDiffCommitSha)
          ? null
          : (diffCommitSha ?? this.diffCommitSha),
      viewingPath: clearViewing ? null : (viewingPath ?? this.viewingPath),
      viewingFile: clearViewing ? null : (viewingFile ?? this.viewingFile),
      viewingLoading: clearViewing
          ? false
          : (viewingLoading ?? this.viewingLoading),
      // Survives clearDiff/clearViewing: closing a diff is not a reason to
      // reopen every folder the user shut to find it.
      collapsedPaths: collapsedPaths ?? this.collapsedPaths,
      sync: sync ?? this.sync,
      syncing: clearSyncing ? null : (syncing ?? this.syncing),
      lastSyncFailure: clearSyncFailure
          ? null
          : (lastSyncFailure ?? this.lastSyncFailure),
      history: history ?? this.history,
    );
  }
}

/// Right-pane state for the attachment preview overlay.
///
/// A THIRD `file:content` consumer beside [FilesPaneState] and [GitPaneState],
/// deliberately given its own slot rather than borrowing the Files tab's: a
/// preview must not evict the file the user has open in the context panel, and
/// the staged upload it reads lives under `.antgrid/`, which the tree hides.
///
/// Mutated only by openPreview/closePreview. Reading these fields from either
/// tab is a leak.
class PreviewPaneState {
  /// Project-relative, as `file:read` requires — the same key [content] is
  /// matched on when the response lands.
  final String? path;

  /// Shown in the overlay's header while [content] is still in flight, so the
  /// dialog can title itself without waiting for the read.
  final String? displayName;
  final FileContent? content;
  final bool isLoading;

  const PreviewPaneState({
    this.path,
    this.displayName,
    this.content,
    this.isLoading = false,
  });

  static const empty = PreviewPaneState();

  bool get isOpen => path != null;

  PreviewPaneState copyWith({
    String? path,
    String? displayName,
    FileContent? content,
    bool? isLoading,
    bool clear = false,
  }) {
    if (clear) return empty;
    return PreviewPaneState(
      path: path ?? this.path,
      displayName: displayName ?? this.displayName,
      content: content ?? this.content,
      isLoading: isLoading ?? this.isLoading,
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
  final PreviewPaneState preview;

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
    this.preview = PreviewPaneState.empty,
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
    PreviewPaneState? preview,
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
      preview: preview ?? this.preview,
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

/// Reply to a `file:resolve-path` request — a path a terminal program printed
/// (an OSC 8 `file://` hyperlink target), resolved against the checkout the
/// request named. [relPath] is null when the path does not resolve inside
/// that checkout; the app never learns the checkout's absolute root, so only
/// the bridge can make this call.
class FileResolvePathResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String requestId;
  final String? relPath;
  final bool isDirectory;

  const FileResolvePathResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.requestId,
    this.relPath,
    this.isDirectory = false,
  });
}
