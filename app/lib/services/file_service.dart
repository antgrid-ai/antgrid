import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../analytics/events.dart';
import '../models/file_tree_models.dart';
import '../models/preferences_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import 'reply_latch.dart';

/// Per-project file tree + git status + viewing-file service.
///
/// Constructed at [ProjectSession] creation time. Subscribes to both the
/// heavy tier (tree snapshots/updates, file content) and the status tier
/// (`git:status`, `git:diff-content` — low-freq drawer-relevant and RPC
/// reply respectively) in the constructor — before any agent message
/// arrives — so welcome-cached replays are caught reliably. The service's
/// lifetime is bound to the session; calling [dispose] cancels both
/// subscriptions and closes the state controller.
class FileService {
  final ProjectSession session;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  int _snapshotSeq = -1;
  int _gitOpSeq = 0;
  bool _disposed = false;

  final _stateController = StreamController<FileTreeState>.broadcast();
  FileTreeState _state;

  Stream<FileTreeState> get stateStream => _stateController.stream;
  FileTreeState get currentState => _state;

  String get projectId => session.projectId;

  /// Notified when a fragmentable transfer (file:content, git:diff-content)
  /// lands, so the recovery coordinator can reset its retry counter.
  void Function(FragHint hint)? onFragmentSuccess;

  /// Wall-clock bound for the one-shot git:diff verb. The frag-abort backstop
  /// ([handleFragmentFailure]) only fires once a fragmented transfer STARTS then
  /// aborts; a send dropped before any frame arrives (keyless relay window /
  /// session down) has no backstop and would strand [GitState.diffLoading].
  /// Injectable so tests drive a short window.
  final Duration gitActionTimeout;
  ReplyLatch? _diffLatch;

  FileService.fromSession(
    this.session, {
    this.gitActionTimeout = const Duration(seconds: 15),
  }) : _state = FileTreeState(projectId: session.projectId) {
    _heavySub = session.heavyStream.listen(_onHeavyJson);
    _statusSub = session.statusStream.listen(_onStatusJson);
  }

  void _setState(FileTreeState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    if (parsed is FileTreeSnapshotMessage) {
      _snapshotSeq = parsed.seq;
      _setState(_state.copyWith(root: parsed.tree));
      return;
    }
    if (parsed is TreeUpdateMessage) {
      final seq = parsed.seq;
      if (seq != null && _snapshotSeq >= 0 && seq <= _snapshotSeq) {
        return; // stale — drop
      }
      _mergeTreeUpdate(parsed);
      return;
    }
    if (parsed is TreeFullMessage) {
      final seq = parsed.seq;
      if (seq != null && _snapshotSeq >= 0 && seq <= _snapshotSeq) {
        return;
      }
      _handleTreeFull(parsed);
      return;
    }
    if (parsed is FileContentMessage) {
      _handleFileContent(parsed);
      return;
    }
  }

  void _onStatusJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    if (parsed is GitStatusMessage) {
      _handleGitStatus(parsed);
      return;
    }
    if (parsed is GitDiffContentMessage) {
      _handleGitDiffContent(parsed);
      return;
    }
    if (parsed is GitCommitResultMessage) {
      _emitOpFeedback(
        parsed.success
            ? (parsed.sha != null ? 'Committed ${parsed.sha}' : 'Committed')
            : (parsed.error ?? 'Commit failed'),
      );
      return;
    }
    if (parsed is GitDiscardResultMessage) {
      _emitOpFeedback(
        parsed.success
            ? 'Discarded changes'
            : (parsed.error ?? 'Discard failed'),
      );
      return;
    }
  }

  /// Surface a one-shot git op result. Bumping the seq makes each result a
  /// distinct event so the toaster re-fires even on an identical message — no
  /// clear-first dance, no coupling to the toaster's de-dup internals.
  void _emitOpFeedback(String message) {
    _setState(
      _state.copyWith(gitOpFeedback: message, gitOpFeedbackSeq: ++_gitOpSeq),
    );
  }

  void _handleTreeFull(TreeFullMessage msg) {
    final preserveExpanded = msg.projectId == _state.projectId;
    _setState(
      _state.copyWith(
        root: msg.root,
        projectId: msg.projectId,
        expandedPaths: preserveExpanded ? _state.expandedPaths : {},
      ),
    );
  }

  void _mergeTreeUpdate(TreeUpdateMessage msg) {
    final currentRoot = _state.root;
    if (currentRoot == null) return;

    var newRoot = _cloneNode(currentRoot);

    for (final removedPath in msg.removed) {
      newRoot = _removeNode(newRoot, removedPath);
    }

    for (final node in [...msg.added, ...msg.modified]) {
      newRoot = _insertOrReplaceNode(newRoot, node);
    }

    final viewingModified =
        _state.files.selectedFilePath != null &&
        msg.modified.any((node) => node.path == _state.files.selectedFilePath);

    _setState(
      _state.copyWith(
        root: newRoot,
        files: viewingModified
            ? _state.files.copyWith(fileModifiedExternally: true)
            : _state.files,
      ),
    );
  }

  void _handleFileContent(FileContentMessage msg) {
    // A single file:read response can target the Files pane, the Git "View
    // File from diff" pane, or both — route by path-match per pane.
    final content = FileContent(
      path: msg.path,
      content: msg.content,
      size: msg.size,
      error: msg.error,
      encoding: msg.encoding,
      mimeType: msg.mimeType,
    );
    if (msg.error == null) {
      onFragmentSuccess?.call(FragHint('file:content', msg.path));
    }
    final files = msg.path == _state.files.selectedFilePath
        ? _state.files.copyWith(
            viewingFile: content,
            isLoading: false,
            fileModifiedExternally: false,
          )
        : _state.files;
    final git = msg.path == _state.git.viewingPath
        ? _state.git.copyWith(viewingFile: content, viewingLoading: false)
        : _state.git;
    if (identical(files, _state.files) && identical(git, _state.git)) return;
    _setState(_state.copyWith(files: files, git: git));
  }

  void _handleGitStatus(GitStatusMessage msg) {
    final statuses = <String, String>{};
    for (final f in msg.files) {
      statuses[f.path] = f.status;
    }
    final openPath = _state.git.diffPath ?? _state.git.viewingPath;
    final clearStaleGit = openPath != null && !statuses.containsKey(openPath);
    _setState(
      _state.copyWith(
        gitFileStatuses: statuses,
        git: clearStaleGit
            ? _state.git.copyWith(clearDiff: true, clearViewing: true)
            : _state.git,
      ),
    );
  }

  void _handleGitDiffContent(GitDiffContentMessage msg) {
    onFragmentSuccess?.call(FragHint('git:diff-content', msg.path));
    if (msg.path != _state.git.diffPath) return;
    _diffLatch?.settle();
    _diffLatch = null;
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          diffContent: msg.diff,
          diffAdditions: msg.additions,
          diffDeletions: msg.deletions,
          diffLoading: false,
        ),
      ),
    );
  }

  /// A fragmented transfer for [hint] aborted and exhausted its retries. Clear
  /// the pane that was awaiting it so the UI stops showing a loading spinner.
  void handleFragmentFailure(FragHint hint) {
    switch (hint.type) {
      case 'file:content':
        _failFileContent(hint.key);
      case 'git:diff-content':
        _failDiff(hint.key);
    }
  }

  void _failFileContent(String path) {
    final errored = FileContent(
      path: path,
      size: 0,
      error: 'Transfer failed — file too large to receive over the relay.',
    );
    final files = path == _state.files.selectedFilePath
        ? _state.files.copyWith(
            viewingFile: errored,
            isLoading: false,
            fileModifiedExternally: false,
          )
        : _state.files;
    final git = path == _state.git.viewingPath
        ? _state.git.copyWith(viewingFile: errored, viewingLoading: false)
        : _state.git;
    if (identical(files, _state.files) && identical(git, _state.git)) return;
    _setState(_state.copyWith(files: files, git: git));
  }

  void _failDiff(String path) {
    if (path != _state.git.diffPath) return;
    _diffLatch?.settle();
    _diffLatch = null;
    _setState(_state.copyWith(git: _state.git.copyWith(diffLoading: false)));
  }

  FileNode _cloneNode(FileNode node) {
    return FileNode(
      name: node.name,
      path: node.path,
      type: node.type,
      size: node.size,
      extension: node.extension,
      children: node.children.map(_cloneNode).toList(),
    );
  }

  FileNode _removeNode(FileNode root, String targetPath) {
    if (root.type != FileNodeType.directory) return root;
    final newChildren = <FileNode>[];
    for (final child in root.children) {
      if (child.path == targetPath) continue;
      newChildren.add(_removeNode(child, targetPath));
    }
    return FileNode(
      name: root.name,
      path: root.path,
      type: root.type,
      size: root.size,
      extension: root.extension,
      children: newChildren,
    );
  }

  FileNode _insertOrReplaceNode(FileNode root, FileNode node) {
    final parts = node.path.split('/');
    if (parts.length <= 1) {
      return _insertChildInto(root, node);
    }
    final parentPath = parts.sublist(0, parts.length - 1).join('/');
    return _insertAtPath(root, parentPath, node);
  }

  FileNode _insertAtPath(FileNode current, String parentPath, FileNode node) {
    if (current.path == parentPath && current.type == FileNodeType.directory) {
      return _insertChildInto(current, node);
    }
    if (current.type != FileNodeType.directory) return current;
    final newChildren = current.children.map((child) {
      return _insertAtPath(child, parentPath, node);
    }).toList();
    return FileNode(
      name: current.name,
      path: current.path,
      type: current.type,
      size: current.size,
      extension: current.extension,
      children: newChildren,
    );
  }

  FileNode _insertChildInto(FileNode parent, FileNode node) {
    final newChildren = <FileNode>[];
    bool replaced = false;
    for (final child in parent.children) {
      if (child.path == node.path) {
        newChildren.add(node);
        replaced = true;
      } else {
        newChildren.add(child);
      }
    }
    if (!replaced) {
      newChildren.add(node);
    }
    newChildren.sort((a, b) {
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
      name: parent.name,
      path: parent.path,
      type: parent.type,
      size: parent.size,
      extension: parent.extension,
      children: newChildren,
    );
  }

  void applyPreferences(ProjectPreferences prefs) {
    final selected = prefs.selectedFilePath;
    _setState(
      _state.copyWith(
        expandedPaths: prefs.expandedPaths,
        showChangedOnly: prefs.showChangedOnly,
        files: selected == null
            ? _state.files.copyWith(clearSelectedFilePath: true)
            : _state.files.copyWith(selectedFilePath: selected),
      ),
    );
    if (selected != null) {
      session.hydrate('file:selected', _hydrateSelectedFile);
    } else {
      session.unhydrate('file:selected');
    }
  }

  void toggleExpanded(String path) {
    final expanded = Set<String>.from(_state.expandedPaths);
    if (expanded.contains(path)) {
      expanded.remove(path);
    } else {
      expanded.add(path);
    }
    _setState(_state.copyWith(expandedPaths: expanded));
  }

  void selectFile(String path, {int? searchLine, String? searchQuery}) {
    // Fire here, not in requestFileContent — the latter is a shared chokepoint
    // also hit by session-restore, fragment recovery, git "view file", and
    // refresh, none of which is a user opening a file from the explorer.
    session.analytics?.track(AnalyticsEvents.fileOpened);
    _setState(
      _state.copyWith(
        files: _state.files.copyWith(
          selectedFilePath: path,
          isLoading: true,
          fileModifiedExternally: false,
          searchLine: searchLine,
          searchQuery: searchQuery,
          clearSearchLine: searchLine == null,
          clearSearchQuery: searchQuery == null,
        ),
      ),
    );
    // Register (fires now if established) rather than sending inline — see
    // [_hydrateSelectedFile]. Re-registering under the same key supersedes, so
    // opening a new file replaces the prior file's hydrator.
    session.hydrate('file:selected', _hydrateSelectedFile);
  }

  void requestFileContent(String path) {
    session.send(
      createAbMessage('file:read', {'projectId': projectId, 'path': path}),
    );
  }

  /// Tier-3 hydrator for the open file. [selectFile] / [applyPreferences]
  /// register this instead of sending `file:read` inline, so the read re-fires
  /// on every (re)establishment (the reconciliation checkpoint) AND a selection
  /// made during a session-down window — where an inline send seals-and-vanishes
  /// and leaves `isLoading` stuck — lands once the stream establishes. Reads the
  /// selection from `_state` dynamically so a re-register (opening a different
  /// file) always pulls the file that is CURRENTLY open.
  Future<void> _hydrateSelectedFile() async {
    if (_disposed) return;
    final selected = _state.files.selectedFilePath;
    if (selected == null) return;
    requestFileContent(selected);
  }

  void requestFullTree() {
    _setState(_state.copyWith(expandedPaths: {}));
    session.send(createAbMessage('tree:request', {'projectId': projectId}));
  }

  void setFilterQuery(String? query) {
    if (query == null) {
      _setState(_state.copyWith(clearFilterQuery: true));
    } else {
      _setState(_state.copyWith(filterQuery: query));
    }
  }

  void clearViewingFile() {
    _setState(
      _state.copyWith(
        files: _state.files.copyWith(
          clearViewingFile: true,
          clearSelectedFilePath: true,
          isLoading: false,
          fileModifiedExternally: false,
        ),
      ),
    );
    // Nothing open — drop the re-drive so a reconnect doesn't re-pull a closed
    // file.
    session.unhydrate('file:selected');
  }

  /// Stage [files] and commit them with [message]. Result (success or error)
  /// arrives as git:commit-result and is surfaced via [gitOpFeedback]; the
  /// changed-file list refreshes automatically from the bridge's git:status.
  void commit(String message, List<String> files) {
    session.send(
      createAbMessage('git:commit', {
        'projectId': projectId,
        'message': message,
        'files': files,
      }),
    );
  }

  /// Discard working-tree changes for [files] (tracked -> restore, untracked ->
  /// clean). Unrecoverable -- callers must confirm first.
  void discard(List<String> files) {
    session.send(
      createAbMessage('git:discard', {'projectId': projectId, 'files': files}),
    );
  }

  void requestDiff(String path) {
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          diffPath: path,
          diffLoading: true,
          clearViewing: true,
        ),
      ),
    );
    // Tier-2 one-shot: bound git:diff on wall-clock so a send dropped before any
    // frame arrives clears diffLoading. Guarded on diffPath so a superseding
    // diff (or a navigate-away) can't have its spinner cleared by a stale
    // timeout. The frag-abort backstop still handles mid-transfer aborts.
    _diffLatch?.settle();
    final latch = _diffLatch = ReplyLatch();
    session.send(
      createAbMessage('git:diff', {'projectId': projectId, 'path': path}),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed || _diffLatch != latch || _state.git.diffPath != path) {
          return;
        }
        _diffLatch = null;
        _setState(
          _state.copyWith(git: _state.git.copyWith(diffLoading: false)),
        );
      }),
    );
  }

  void toggleChangedOnly() {
    _setState(_state.copyWith(showChangedOnly: !_state.showChangedOnly));
  }

  void clearDiff() {
    // Superseded by the user closing the diff — a clean end, not a strand.
    _diffLatch?.settle();
    _diffLatch = null;
    _setState(_state.copyWith(git: _state.git.copyWith(clearDiff: true)));
  }

  /// Git pane: enter "View File from diff" mode. Clears the diff and starts
  /// loading the file's content into the Git pane (separate from any file the
  /// Files tab may have selected).
  void gitViewFile(String path) {
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          clearDiff: true,
          viewingPath: path,
          viewingLoading: true,
        ),
      ),
    );
    requestFileContent(path);
  }

  /// Git pane: exit "View File from diff" mode, returning to the changed-files
  /// list (or the active diff, if one is still set).
  void clearGitViewing() {
    _setState(_state.copyWith(git: _state.git.copyWith(clearViewing: true)));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Resolve any in-flight git:diff action so its timeout timer is cancelled.
    _diffLatch?.settle();
    _diffLatch = null;
    session.unhydrate('file:selected');
    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _stateController.close();
  }
}
