import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import '../analytics/events.dart';
import '../models/file_tree_models.dart';
import '../models/preferences_models.dart';
import '../models/ab_message.dart';
import '../models/git_sync_state.dart';
import '../project/project_session.dart';
import '../util/detached.dart';
import 'pending_reply.dart';
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
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<void>? _resumeSub;
  int _snapshotSeq = -1;

  /// The establishment [_snapshotSeq] was issued under — see [_claimableSeq].
  int _snapshotEpoch = -1;
  int _gitOpSeq = 0;
  bool _disposed = false;
  bool _treeRecoveryPending = false;
  final Set<Object> _treeOwners = {};
  bool get hasTreeInterest => _treeOwners.isNotEmpty;

  /// The seq of the last `file:tree:children` listing this service applied
  /// for each path (root included, under `''`), paired with the establishment
  /// that issued it — the per-path freshness gate a rapid double-expand
  /// needs. `file:tree:children:request` carries no id to echo, so the
  /// bridge's own revision counter is the only thing that tells a reply's
  /// request apart from an earlier one for the SAME path; see
  /// [_isFreshListing]. The epoch is not optional: the counter is
  /// per-agent-PROCESS and restarts at zero, so a seq compared across a
  /// restart judges every listing the new agent sends as stale and freezes
  /// the tree for the life of the service — the same hazard [_claimableSeq]
  /// guards [_snapshotSeq] against.
  final Map<String, ({int seq, int epoch})> _listingSeq = {};

  void setTreeInterest(Object owner, bool interested) {
    if (_disposed) return;
    final hadInterest = hasTreeInterest;
    if (interested) {
      _treeOwners.add(owner);
    } else {
      _treeOwners.remove(owner);
    }
    if (hadInterest == hasTreeInterest) return;
    if (hasTreeInterest) {
      session.hydrateCheckout(checkoutId, _treeHydratorKey, _hydrateTree);
      // Background suppression drops deltas, so a visible tree must validate its
      // revision even when resuming did not establish a new transport.
      _resumeSub ??= session.focusResumed.listen(
        (_) =>
            detached('FileService', 'tree re-pull on focus resume', () async {
              if (hasTreeInterest) await _hydrateTree();
            }),
      );
    } else {
      session.unhydrateCheckout(checkoutId, _treeHydratorKey);
      unawaited(_resumeSub?.cancel());
      _resumeSub = null;
    }
  }

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

  /// Bounds a `git:log` page fetch the same way [_diffLatch] bounds
  /// `git:diff` — one slot, superseded on the next fetch (a scroll-triggered
  /// load is guarded against firing while one is already in flight, so there
  /// is never more than one page request to bound at a time).
  ReplyLatch? _historyLatch;

  /// The offset [_historyLatch] is waiting on. `git:log-result` carries no
  /// request id, and the offset is the only thing that distinguishes one page
  /// from another — see [_handleGitLogResult] for what a mismatched page costs.
  int? _pendingLogSkip;

  /// Bounds `git:commit-files`, keyed by sha rather than a single slot like
  /// [_historyLatch]: the History tab lets more than one commit's file list
  /// stay expanded and loading at once (see [GitHistoryState]), so a dropped
  /// send for one commit must not settle another's in-flight fetch.
  final Map<String, ReplyLatch> _commitFilesLatches = {};

  /// Wall-clock bound for push/pull. Longer than [gitActionTimeout] because
  /// these reach the network — and load-bearing beyond the usual dropped-send
  /// case: a bridge predating `git:sync` DROPS the verb silently, and there is
  /// no bridge-to-app feature negotiation to check instead, so this timeout is
  /// the only thing that clears the spinner against an older host.
  final Duration gitSyncTimeout;
  ReplyLatch? _syncLatch;

  /// In-flight `file:resolve-path` round trips, keyed by requestId — plural
  /// unlike [_diffLatch]/[_syncLatch] because more than one terminal link can
  /// be clicked (or hovered-then-clicked from two terminals) before either
  /// answer lands.
  final Map<String, PendingReply<FileResolvePathResultMessage>>
  _pendingResolves = {};

  FileService.fromSession(
    this.session, {
    this.checkoutId = 'main',
    this.gitActionTimeout = const Duration(seconds: 15),
    this.gitSyncTimeout = const Duration(seconds: 150),
  }) : _state = FileTreeState(projectId: session.projectId) {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
    // The bridge caches `git:sync-state` for replay, but only a checkout whose
    // bundle existed at connect time receives that replay — an isolated
    // session's does not. Asking also re-fires on every reconnect, which is
    // what keeps the indicator from sitting on counts from before a drop. Kept
    // eager (not gated behind [activate]) because it feeds drawer/status
    // chrome for every checkout, not just the one on screen — see
    // [ProjectSession.setActiveCheckouts].
    session.hydrateCheckout(checkoutId, _syncHydratorKey, _hydrateSyncState);
    // History is deliberately NOT hydrated here the way sync state is: it has
    // no consumer besides the Git panel (every FileService exists whether or
    // not that panel is ever opened), so eager-on-construct hydration would
    // cost every project session a `git:log` round trip for a view most never
    // visit. `GitPanel` triggers the first load itself once it is actually
    // built with an empty history — see its `_maybeLoadHistory`.
  }

  static const _treeHydratorKey = 'file:tree';
  static const _syncHydratorKey = 'git:sync-state';

  /// Restores selected-file and preview pulls independently of full-tree demand.
  void activate() {
    if (_disposed) return;
    if (_stashesRequested) {
      session.hydrateCheckout(checkoutId, _stashHydratorKey, _hydrateStashes);
    }
    if (_state.files.selectedFilePath != null) {
      session.hydrateCheckout(
        checkoutId,
        'file:selected',
        _hydrateSelectedFile,
      );
    }
    if (_state.preview.isOpen) {
      session.hydrateCheckout(checkoutId, 'file:preview', _hydratePreview);
    }
  }

  /// Leaves cached content and feature-owned tree demand intact.
  void deactivate() {
    if (_disposed) return;
    session.unhydrateCheckout(checkoutId, _stashHydratorKey);
    session.unhydrateCheckout(checkoutId, 'file:selected');
    session.unhydrateCheckout(checkoutId, 'file:preview');
  }

  /// The tree pull behind both the hydrator and the focus-resume re-drive.
  /// Names the revision this checkout holds where that revision can still be
  /// believed, so an unchanged tree is answered `file:tree:unchanged` rather
  /// than in full.
  ///
  /// Claiming is worth the care because the unchanged answer is the common one:
  /// every open project's every active checkout re-pulls on the same resume
  /// edge, and activation is per-focused-checkout, so switching away from a
  /// checkout and back re-runs this too — on an idle tree each of those answers
  /// was a byte-identical few hundred KB.
  Future<void> _pullTree() => _requestTree(sinceSeq: _claimableSeq());

  /// The held revision, or null when it cannot be believed.
  ///
  /// A seq is only comparable against the establishment that issued it. A
  /// hydrator run means the transport re-established, and the agent behind it
  /// may be a NEW PROCESS whose revision counter restarted at zero — a claim
  /// carried across could then match by coincidence and have a stale tree
  /// confirmed. The epoch is what separates that from the cases where the agent
  /// is demonstrably the same one that issued the seq: a focus resume, which
  /// re-establishes nothing (see [MessageRouter.focusResumed]), and a checkout
  /// returning to screen on a transport that never dropped.
  int? _claimableSeq() {
    if (_snapshotSeq < 0) return null;
    if (_snapshotEpoch != session.establishmentEpoch) return null;
    return _snapshotSeq;
  }

  /// Records [seq] together with the establishment that issued it. Every write
  /// to [_snapshotSeq] goes through here — a seq stored without its epoch would
  /// be claimed against the wrong agent.
  void _rememberSeq(int seq) {
    _snapshotSeq = seq;
    _snapshotEpoch = session.establishmentEpoch;
  }

  Future<void> _requestTree({int? sinceSeq}) => session.sendForCheckout(
    checkoutId,
    createAbMessage('file:tree:root:request', {
      'sinceSeq': ?sinceSeq,
      // Never rely on the bridge's Zod default — parseMessageFast validates
      // only the message TYPE, so an omitted field arrives as `undefined`,
      // never `true` (D10: the tree shows git-ignored files by default).
      'includeIgnored': true,
    }),
  );

  /// Tier-3 hydrator for the whole visible tree: re-confirms the root
  /// revision via [_pullTree], then re-lists every directory the user
  /// currently has open. Doubles as the recovery path for a directory whose
  /// `file:tree:children:request` never got answered — a checkout torn down
  /// mid-flight, a reconnect racing the reply, or a relay drop — since
  /// nothing else ever clears [FileNode.childrenLoading]: the next
  /// (re)establishment simply re-issues the request rather than leaving the
  /// folder spinning forever.
  Future<void> _hydrateTree() async {
    await _pullTree();
    await _fetchChildrenChunked(_state.expandedPaths);
  }

  static const int _childrenRequestBatchLimit = 64;

  /// Fetches every path in [paths] in batches of at most 64, issued
  /// concurrently and applied as each lands — restoring 100 remembered
  /// folders costs 2 round trips, not 100. The limit matches the bridge's
  /// own clamp (`MAX_CHILDREN_REQUEST_PATHS`): understating it here would
  /// not cost more round trips, it would silently LOSE paths past the clamp.
  ///
  /// Shallowest-first, so a chunk's replies can be placed under parents that
  /// are already on the spine — see [_handleChildrenMessage].
  Future<void> _fetchChildrenChunked(Iterable<String> paths) {
    final ordered = paths.toSet().toList()
      ..sort((a, b) => _depthOf(a).compareTo(_depthOf(b)));
    if (ordered.isEmpty) return Future.value();
    _markLoading(ordered);
    final sends = <Future<void>>[];
    for (var i = 0; i < ordered.length; i += _childrenRequestBatchLimit) {
      final end = i + _childrenRequestBatchLimit < ordered.length
          ? i + _childrenRequestBatchLimit
          : ordered.length;
      sends.add(_requestChildren(ordered.sublist(i, end)));
    }
    return Future.wait(sends);
  }

  int _depthOf(String path) => path.isEmpty ? 0 : path.split('/').length;

  /// Marks every directory about to be listed as pending, so the tree's
  /// loading row covers the expanded-set restore, reveal, select and the
  /// post-invalidation re-list — not just a manual expand. Without it an
  /// expanded directory that has never been listed renders identically to an
  /// empty one for the whole round trip, and indefinitely if the reply is
  /// dropped. Cleared by [_applyListing].
  void _markLoading(Iterable<String> paths) {
    final current = _state.root;
    if (current == null) return;
    var root = current;
    for (final path in paths) {
      if (path.isEmpty) continue;
      root = _updateAt(
        root,
        path,
        (dir) => _rebuild(dir, childrenLoading: true),
      );
    }
    if (!identical(root, current)) {
      _setState(_state.copyWith(root: root));
    }
  }

  Future<void> _requestChildren(List<String> paths) {
    if (paths.isEmpty) return Future.value();
    return session.sendForCheckout(
      checkoutId,
      createAbMessage('file:tree:children:request', {
        'paths': paths,
        'includeIgnored': true,
      }),
    );
  }

  void _setState(FileTreeState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    // TODO(wave-6): nothing here sends `file:tree:snapshot:request` any more
    // (see [_requestTree]), but the bridge answers it on the BUS, so a
    // second client still running the whole-tree build makes its reply
    // arrive here. Applying it would swap the lazily-listed, show-all tree
    // for the legacy ignore-respecting depth-capped one and move the seq
    // claim with it. Delete alongside the bridge's
    // `case "file:tree:snapshot:request"` and [_handleTreeFull].
    if (parsed is FileTreeSnapshotMessage) {
      return;
    }
    if (parsed is FileTreeUnchangedMessage) {
      // Nothing to apply — the agent is confirming the revision we claimed.
      // Guarded anyway so a confirmation that raced an applied delta cannot
      // walk the base backwards and re-admit an update already merged.
      if (_snapshotSeq >= 0 && parsed.seq == _snapshotSeq) {
        _treeRecoveryPending = false;
      }
      return;
    }
    if (parsed is FileTreeChildrenMessage) {
      _handleChildrenMessage(parsed);
      return;
    }
    if (parsed is FileTreeInvalidatedMessage) {
      _handleInvalidated(parsed);
      return;
    }
    if (parsed is TreeUpdateMessage) {
      final seq = parsed.seq;
      if (seq != null && _snapshotSeq >= 0 && seq <= _snapshotSeq) {
        return; // stale — drop
      }
      _applyTreeUpdate(parsed);
      // Only a CONTIGUOUS delta may advance the base. A gap means the agent
      // suppressed updates while this app was backgrounded and dropped them
      // (it keeps counting through a suppression window), so the tree here is
      // missing whatever those carried. Leaving the base behind is exactly what
      // makes the next resume ask for a full tree rather than have a stale one
      // confirmed.
      if (seq != null && _snapshotSeq >= 0 && seq == _snapshotSeq + 1) {
        _rememberSeq(seq);
      } else {
        _snapshotSeq = -1;
        if (hasTreeInterest && !_treeRecoveryPending) {
          _treeRecoveryPending = true;
          detached('FileService', 'recover tree sequence gap', _pullTree);
        }
      }
      return;
    }
    if (parsed is TreeFullMessage) {
      _handleTreeFull(parsed);
      return;
    }
    if (parsed is FileContentMessage) {
      _handleFileContent(parsed);
      return;
    }
    if (parsed is FileResolvePathResultMessage) {
      _pendingResolves.remove(parsed.requestId)?.complete(parsed);
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
    // Stage/unstage are silent on success (like VS Code — the follow-up
    // git:status refresh is what moves the UI); only a failure needs
    // surfacing, since nothing else would explain it.
    if (parsed is GitStageResultMessage) {
      if (!parsed.success) _emitOpFeedback(parsed.error ?? 'Stage failed');
      return;
    }
    if (parsed is GitUnstageResultMessage) {
      if (!parsed.success) _emitOpFeedback(parsed.error ?? 'Unstage failed');
      return;
    }
    if (parsed is GitStashListResultMessage) {
      if (parsed.error == null) {
        _setState(
          _state.copyWith(git: _state.git.copyWith(stashes: parsed.stashes)),
        );
      }
      return;
    }
    // Neither result asks for the list back: the agent already follows every
    // pop and drop with a fresh `git:stash-list-result` on both outcomes, so a
    // request here is a second round trip for a list already on its way.
    if (parsed is GitStashPopResultMessage) {
      if (!parsed.success) {
        _emitOpFeedback(parsed.error ?? 'Could not restore the stash');
      }
      return;
    }
    if (parsed is GitStashDropResultMessage) {
      if (!parsed.success) {
        _emitOpFeedback(parsed.error ?? 'Could not discard the stash');
      }
      return;
    }
    if (parsed is GitSyncResultMessage) {
      _handleGitSyncResult(parsed);
      return;
    }
    if (parsed is GitSyncStateMessage) {
      _setState(_state.copyWith(git: _state.git.copyWith(sync: parsed.state)));
      return;
    }
    if (parsed is GitLogResultMessage) {
      _handleGitLogResult(parsed);
      return;
    }
    if (parsed is GitCommitFilesResultMessage) {
      _handleCommitFilesResult(parsed);
      return;
    }
    if (parsed is GitCommitDiffContentMessage) {
      _handleGitCommitDiffContent(parsed);
      return;
    }
  }

  void _handleGitSyncResult(GitSyncResultMessage msg) {
    // A result for an op we are not waiting on is stale — a push whose latch
    // already timed out, landing after the user started a pull. Settling the
    // pull's latch on it would clear `syncing`, toast "Push complete" and
    // re-enable both buttons while the pull is still running, and the pull's
    // own reply would then arrive with nothing left to settle. A result with
    // NO op in flight still lands: that is the other device having synced, and
    // its outcome is the honest state for this one too.
    final syncing = _state.git.syncing;
    if (syncing != null && msg.op != syncing) return;
    _syncLatch?.settle();
    _syncLatch = null;
    final failure = msg.failure;
    // Two branches rather than one call passing both a value and its clear
    // flag: that combination is ambiguous by house rule, and here it would
    // also be wrong — `lastSyncFailure: null` reads as "unchanged", so a
    // success would leave the previous failure's offer standing.
    final git = failure == null
        ? _state.git.copyWith(clearSyncing: true, clearSyncFailure: true)
        : _state.git.copyWith(clearSyncing: true, lastSyncFailure: failure);
    _setState(_state.copyWith(git: git));
    // Toasted even when the panel will also offer the agent handoff: the
    // handoff is an affordance the user may never look at, and a failure that
    // said nothing at all would read as a button that did nothing.
    _emitOpFeedback(
      failure == null
          ? (msg.summary ?? '${msg.op.label} complete')
          : failure.message,
    );
  }

  /// Surface a one-shot git op result. Bumping the seq makes each result a
  /// distinct event so the toaster re-fires even on an identical message — no
  /// clear-first dance, no coupling to the toaster's de-dup internals.
  void _emitOpFeedback(String message) {
    _setState(
      _state.copyWith(gitOpFeedback: message, gitOpFeedbackSeq: ++_gitOpSeq),
    );
  }

  // TODO(wave-6): the bridge still force-resends the whole tree on watcher
  // overflow; this app now reacts to the sibling `file:tree:invalidated`
  // push instead (see [_handleInvalidated]) and ignores this one entirely.
  // Remove the bridge's resend once every deployed app speaks
  // file:tree:root, and delete this method then.
  void _handleTreeFull(TreeFullMessage msg) {}

  /// Applies an incremental `tree:update` delta using the same
  /// identity-preserving spine copy [_handleChildrenMessage] uses — see
  /// [_updateAt]. A delta into a directory this app has never fetched has
  /// nothing to insert INTO (dropped); a delta into one whose listing was
  /// TRUNCATED cannot be inserted locally either — `children` there is an
  /// ordered PREFIX, and there is no way to know whether the changed node
  /// belongs inside that prefix or past the cut the bridge already made — so
  /// that directory is queued for [_fetchChildrenChunked] instead.
  void _applyTreeUpdate(TreeUpdateMessage msg) {
    final currentRoot = _state.root;
    if (currentRoot == null) return;

    var root = currentRoot;
    final relist = <String>{};

    for (final removedPath in msg.removed) {
      root = _applyToParent(root, removedPath, relist, (parent) {
        final children = parent.children
            .where((c) => c.path != removedPath)
            .toList();
        return _rebuild(parent, children: children);
      });
    }

    for (final node in [...msg.added, ...msg.modified]) {
      root = _applyToParent(root, node.path, relist, (parent) {
        FileNode? prior;
        for (final child in parent.children) {
          if (child.path == node.path) prior = child;
        }
        final children = _sorted([
          ...parent.children.where((c) => c.path != node.path),
          _deltaNode(node, prior),
        ]);
        return _rebuild(parent, children: children);
      });
    }

    final viewingModified =
        _state.files.selectedFilePath != null &&
        msg.modified.any((node) => node.path == _state.files.selectedFilePath);

    if (!identical(root, currentRoot) || viewingModified) {
      _setState(
        _state.copyWith(
          root: root,
          files: viewingModified
              ? _state.files.copyWith(fileModifiedExternally: true)
              : _state.files,
        ),
      );
    }

    if (relist.isNotEmpty) {
      detached(
        'FileService',
        're-list truncated directory after a delta',
        () => _fetchChildrenChunked(relist),
      );
    }
  }

  /// Reconciles one `tree:update` entry with what the app already holds at
  /// that path.
  ///
  /// A delta entry for a DIRECTORY is not a listing. `FileWatcher.onDirAdded`
  /// emits `children: []` without ever reading the directory — and on Windows
  /// and macOS the native recursive watcher raises a directory event for the
  /// parent of every file write — so [FileNode.fromJson]'s "a `children` key
  /// means the bridge listed it" rule reads it as an authoritative empty and
  /// blanks whatever was expanded there. Neither the carried-over state nor
  /// the unloaded fallback can be wrong: the bridge did not look inside.
  FileNode _deltaNode(FileNode node, FileNode? prior) {
    if (node.type != FileNodeType.directory) return node;
    if (prior == null || prior.type != FileNodeType.directory) {
      return _rebuild(node, children: const [], childrenLoaded: false);
    }
    return _rebuild(
      node,
      children: prior.children,
      truncated: prior.truncated,
      childrenLoaded: prior.childrenLoaded,
      childrenLoading: prior.childrenLoading,
    );
  }

  /// Routes one `tree:update` entry (add/modify/remove, named by
  /// [targetPath]) to its parent directory and applies [edit] to it — or, if
  /// the parent is not loaded or is truncated, leaves [root] untouched (and
  /// for a truncated parent, records it in [relist]). See
  /// [_applyTreeUpdate]'s doc for why those two cases cannot apply locally.
  FileNode _applyToParent(
    FileNode root,
    String targetPath,
    Set<String> relist,
    FileNode Function(FileNode parent) edit,
  ) {
    final parts = targetPath.split('/');
    final parentPath = parts.length <= 1
        ? ''
        : parts.sublist(0, parts.length - 1).join('/');
    final parent = _findNode(root, parentPath);
    if (parent == null || !parent.childrenLoaded) return root;
    if (parent.truncated) {
      // A re-list already in flight covers every delta that lands while it
      // is out — without this a directory under a build's churn re-lists up
      // to 2000 nodes on every 6 Hz flush, which is the traffic this whole
      // change exists to cut.
      if (!parent.childrenLoading) relist.add(parentPath);
      return root;
    }
    return _updateAt(root, parentPath, edit);
  }

  /// Read-only lookup by path — the root's own path is `''`.
  FileNode? _findNode(FileNode node, String path) {
    if (node.path == path) return node;
    if (node.type != FileNodeType.directory) return null;
    for (final child in node.children) {
      if (path == child.path || path.startsWith('${child.path}/')) {
        return _findNode(child, path);
      }
    }
    return null;
  }

  /// Rebuilds only the spine from [root] down to the directory at [dirPath],
  /// applying [fn] to it and reusing every sibling subtree BY REFERENCE. The
  /// merge path this replaced deep-cloned the whole tree on every delta — at
  /// up to 6 Hz, on the UI thread — for a change that in practice touches
  /// one directory a few levels deep. A
  /// [dirPath] this service has never listed has no node on the spine to
  /// find, and the walk below simply returns [root] unchanged for it — the
  /// "drop a delta into an unloaded directory" contract [_applyToParent]
  /// relies on for the shallower unloaded-parent case, and load-bearing on
  /// its own wherever a caller passes a path with no live caller-side check.
  FileNode _updateAt(
    FileNode root,
    String dirPath,
    FileNode Function(FileNode dir) fn,
  ) {
    if (root.path == dirPath) return fn(root);
    if (root.type != FileNodeType.directory) return root;
    for (var i = 0; i < root.children.length; i++) {
      final child = root.children[i];
      if (dirPath == child.path || dirPath.startsWith('${child.path}/')) {
        final newChild = _updateAt(child, dirPath, fn);
        if (identical(newChild, child)) return root;
        final newChildren = List<FileNode>.of(root.children);
        newChildren[i] = newChild;
        return _rebuild(root, children: newChildren);
      }
    }
    return root;
  }

  /// Rebuilds [node] with the given fields overridden, everything else
  /// (including [FileNode.ignored], which nothing here ever sets — wave 5)
  /// carried over unchanged. The one node constructor every spine-copy site
  /// below goes through, so a field added to [FileNode] only has to be
  /// threaded here.
  FileNode _rebuild(
    FileNode node, {
    List<FileNode>? children,
    bool? truncated,
    bool? childrenLoaded,
    bool? childrenLoading,
  }) => FileNode(
    name: node.name,
    path: node.path,
    type: node.type,
    size: node.size,
    extension: node.extension,
    children: children ?? node.children,
    truncated: truncated ?? node.truncated,
    childrenLoaded: childrenLoaded ?? node.childrenLoaded,
    childrenLoading: childrenLoading ?? node.childrenLoading,
    ignored: node.ignored,
  );

  List<FileNode> _sorted(List<FileNode> nodes) {
    final sorted = List<FileNode>.of(nodes);
    sorted.sort((a, b) {
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
    return sorted;
  }

  /// Reply to both `file:tree:root:request` and `file:tree:children:request`
  /// — the two are told apart by whether [FileTreeChildrenMessage.listings]
  /// carries a `path: ""` entry, never by message type.
  void _handleChildrenMessage(FileTreeChildrenMessage msg) {
    // Shallowest-first whatever order the bridge answered in: a listing can
    // only be placed under a parent already on the spine, so applying a
    // child's listing before its parent's is the one order guaranteed to
    // lose it.
    final ordered = msg.listings.toList()
      ..sort((a, b) => _depthOf(a.path).compareTo(_depthOf(b.path)));

    var root = _state.root;
    for (final listing in ordered) {
      if (listing.path.isEmpty) {
        // A root the bridge could not answer — its FileWatcher is not up yet
        // — is a NON-answer, not an empty project. Applying it would erase
        // the tree and mark it authoritatively loaded with nothing left to
        // retry from. `missing` on a SUBDIRECTORY still folds into an
        // ordinary empty listing; see [_applyListing].
        if (listing.missing) continue;
        // The root's own listing plays the role `file:tree:snapshot` used
        // to: the revision this reply reflects, claimable on the next root
        // pull via sinceSeq. A children-only reply (an ordinary folder
        // expand) never touches the claim — it answers a different directory
        // entirely. A claim that is no longer believable is REPLACED rather
        // than raised: a restarted agent counts from zero, and refusing to
        // walk back would leave a dead process's seq claimable until the new
        // one caught up to it.
        _treeRecoveryPending = false;
        if (_claimableSeq() == null || msg.seq > _snapshotSeq) {
          _rememberSeq(msg.seq);
        }
      } else if (root == null || _findNode(root, listing.path) == null) {
        // Nothing on the spine to place it under: the directory went away
        // between the request and the reply. Deliberately not re-requested
        // (the re-request would find it gone too) and deliberately not
        // recorded, so a later listing for the same path is not judged
        // against a watermark set by a reply that was never applied.
        continue;
      }
      if (!_isFreshListing(listing.path, msg.seq)) continue;
      _recordListing(listing.path, msg.seq);
      root = _applyListing(root, listing);
    }
    if (!identical(root, _state.root)) {
      _setState(_state.copyWith(root: root));
    }
  }

  /// Applies one directory's listing into [root]. `listing.missing` folds
  /// into an ordinary empty, loaded listing — there is no `FileNode.missing`
  /// to carry the distinction yet, so this stops the directory spinning
  /// forever rather than leaving it pending indefinitely. (The root is the
  /// exception, filtered out by [_handleChildrenMessage] before it gets
  /// here.)
  FileNode? _applyListing(FileNode? root, DirectoryListing listing) {
    if (listing.path.isEmpty) {
      return FileNode(
        name: root?.name ?? '',
        path: '',
        type: FileNodeType.directory,
        children: _sorted(_carryLoaded(listing.children, root)),
        truncated: listing.truncated,
        childrenLoaded: true,
        childrenLoading: false,
        ignored: root?.ignored ?? false,
      );
    }
    if (root == null) return root;
    return _updateAt(
      root,
      listing.path,
      (dir) => _rebuild(
        dir,
        children: _sorted(_carryLoaded(listing.children, dir)),
        truncated: listing.truncated,
        childrenLoaded: true,
        childrenLoading: false,
      ),
    );
  }

  /// Carries an already-loaded subtree across a re-listing of its parent.
  ///
  /// A depth-1 listing names a subdirectory without recursing into it, so
  /// that entry parses `childrenLoaded: false` with no children. Installing
  /// it bare would discard everything the app had fetched below it, and
  /// nothing would ask again: the row stays in `expandedPaths` and renders
  /// expanded, empty and with no loading state — indistinguishable from a
  /// genuinely empty folder, permanently. Every root pull and every
  /// collapse-then-expand of an ancestor would flatten the tree beneath it.
  ///
  /// Matching by path is safe: a rename yields a different path, and a
  /// delete-then-recreate is repaired by the expand gesture, which always
  /// re-lists from disk (D2).
  List<FileNode> _carryLoaded(List<FileNode> incoming, FileNode? previous) {
    if (previous == null || previous.children.isEmpty) return incoming;
    final held = <String, FileNode>{
      for (final child in previous.children) child.path: child,
    };
    final merged = <FileNode>[];
    for (final node in incoming) {
      final prior = held[node.path];
      final carry =
          node.type == FileNodeType.directory &&
          !node.childrenLoaded &&
          prior != null &&
          prior.type == FileNodeType.directory;
      merged.add(
        carry
            ? _rebuild(
                node,
                children: prior.children,
                truncated: prior.truncated,
                childrenLoaded: prior.childrenLoaded,
                childrenLoading: prior.childrenLoading,
              )
            : node,
      );
    }
    return merged;
  }

  /// True iff [seq] is at least as new as the last listing this service
  /// applied for [path]. `file:tree:children:request` carries no id to
  /// echo, so two rapid expands of the same path can only be told apart by
  /// the bridge's own revision counter — a later SEND cannot come back with
  /// a lower seq than an earlier one UNLESS nothing on disk changed between
  /// the two requests, in which case the two replies' content is identical
  /// anyway and applying either is correct. See spec trap 11.
  ///
  /// A seq issued under a different establishment is not comparable at all
  /// (see [_listingSeq]), so it is always fresh. Does NOT record — a listing
  /// that turns out to be unplaceable must not move the watermark; see
  /// [_recordListing].
  bool _isFreshListing(String path, int seq) {
    final last = _listingSeq[path];
    if (last == null) return true;
    if (last.epoch != session.establishmentEpoch) return true;
    return seq >= last.seq;
  }

  void _recordListing(String path, int seq) {
    _listingSeq[path] = (seq: seq, epoch: session.establishmentEpoch);
  }

  /// Pushed when the watcher overflowed and gave up tracking incremental
  /// changes. Clears what every directory believes it has loaded, then
  /// re-lists the root and every expanded directory itself — see
  /// [_hydrateTree].
  void _handleInvalidated(FileTreeInvalidatedMessage msg) {
    final root = _state.root;
    if (root == null) return;
    // The watermarks describe listings of a tree this frame just declared
    // untrustworthy, and every path is about to be asked for again.
    _listingSeq.clear();
    _setState(_state.copyWith(root: _clearAllLoaded(root)));
    detached(
      'FileService',
      're-list after file:tree:invalidated',
      _hydrateTree,
    );
  }

  FileNode _clearAllLoaded(FileNode node) {
    if (node.type != FileNodeType.directory) return node;
    final children = node.children.map(_clearAllLoaded).toList();
    return _rebuild(
      node,
      children: children,
      childrenLoaded: false,
      childrenLoading: false,
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
    final preview = msg.path == _state.preview.path
        ? _state.preview.copyWith(content: content, isLoading: false)
        : _state.preview;
    if (identical(files, _state.files) &&
        identical(git, _state.git) &&
        identical(preview, _state.preview)) {
      return;
    }
    _setState(_state.copyWith(files: files, git: git, preview: preview));
  }

  void _handleGitStatus(GitStatusMessage msg) {
    // Folded in wire order (conflicts, renames/staged, then unstaged, then
    // untracked — see getGitStatus's doc comment on the bridge) so a later
    // duplicate for the same path (unstaged) overwrites an earlier one
    // (staged): "worktree status wins", matching VS Code's own Explorer
    // dedup rule, for free.
    final statuses = <String, String>{};
    for (final f in msg.files) {
      statuses[f.path] = f.status;
    }
    final openPath = _state.git.diffPath ?? _state.git.viewingPath;
    final clearStaleGit = openPath != null && !statuses.containsKey(openPath);
    _setState(
      _state.copyWith(
        gitFileStatuses: statuses,
        gitFileEntries: msg.files,
        git: clearStaleGit
            ? _state.git.copyWith(clearDiff: true, clearViewing: true)
            : _state.git,
      ),
    );
  }

  void _handleGitDiffContent(GitDiffContentMessage msg) {
    onFragmentSuccess?.call(FragHint('git:diff-content', msg.path));
    // Also guards on diffCommitSha being unset: a working-tree diff reply
    // landing after the user has already switched to a commit's diff for the
    // SAME path must not overwrite it.
    if (msg.path != _state.git.diffPath || _state.git.diffCommitSha != null) {
      return;
    }
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

  void _handleGitLogResult(GitLogResultMessage msg) {
    // Correlated on the offset, because the append below is unconditional and
    // a page that is not the one in flight appends the WRONG commits: a
    // timed-out `skip: 50` arriving after the user scrolled and asked for
    // `skip: 50` again lands twice, duplicating commits 51-100 in the list and
    // pushing every later page's offset past real history. The same reply also
    // settles whichever latch is current, so the page actually in flight then
    // has nothing to time out on.
    if (_pendingLogSkip != null && msg.skip != _pendingLogSkip) return;
    _pendingLogSkip = null;
    _historyLatch?.settle();
    _historyLatch = null;
    if (msg.error != null) {
      _setState(
        _state.copyWith(
          git: _state.git.copyWith(
            history: _state.git.history.copyWith(
              loadingMore: false,
              initialLoad: false,
              error: msg.error,
            ),
          ),
        ),
      );
      return;
    }
    // A page fetched with `skip: 0` REPLACES the list (a fresh open of the
    // History tab, or a refresh); any other skip is assumed to continue the
    // list this service itself has been paginating — callers never fetch an
    // arbitrary skip, so there is nothing else it could be appending to.
    final commits = msg.skip == 0
        ? msg.commits
        : [..._state.git.history.commits, ...msg.commits];
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: _state.git.history.copyWith(
            commits: commits,
            loadingMore: false,
            initialLoad: false,
            hasMore: msg.hasMore,
            clearError: true,
          ),
        ),
      ),
    );
  }

  void _handleCommitFilesResult(GitCommitFilesResultMessage msg) {
    _commitFilesLatches.remove(msg.sha)?.settle();
    final loading = Set<String>.from(_state.git.history.filesLoadingShas)
      ..remove(msg.sha);
    if (msg.error != null) {
      final errors = Map<String, String>.from(
        _state.git.history.filesErrorBySha,
      )..[msg.sha] = msg.error!;
      _setState(
        _state.copyWith(
          git: _state.git.copyWith(
            history: _state.git.history.copyWith(
              filesLoadingShas: loading,
              filesErrorBySha: errors,
            ),
          ),
        ),
      );
      return;
    }
    final files = Map<String, List<GitCommitFileEntry>>.from(
      _state.git.history.filesBySha,
    )..[msg.sha] = msg.files;
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: _state.git.history.copyWith(
            filesBySha: files,
            filesLoadingShas: loading,
          ),
        ),
      ),
    );
  }

  void _handleGitCommitDiffContent(GitCommitDiffContentMessage msg) {
    onFragmentSuccess?.call(FragHint('git:commit-diff-content', msg.path));
    if (msg.path != _state.git.diffPath ||
        msg.sha != _state.git.diffCommitSha) {
      return;
    }
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
      case 'git:commit-diff-content':
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
    final preview = path == _state.preview.path
        ? _state.preview.copyWith(content: errored, isLoading: false)
        : _state.preview;
    if (identical(files, _state.files) &&
        identical(git, _state.git) &&
        identical(preview, _state.preview)) {
      return;
    }
    _setState(_state.copyWith(files: files, git: git, preview: preview));
  }

  void _failDiff(String path) {
    if (path != _state.git.diffPath) return;
    _diffLatch?.settle();
    _diffLatch = null;
    _setState(_state.copyWith(git: _state.git.copyWith(diffLoading: false)));
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
      session.hydrateCheckout(
        checkoutId,
        'file:selected',
        _hydrateSelectedFile,
      );
    } else {
      session.unhydrateCheckout(checkoutId, 'file:selected');
    }
    // The persisted expanded set just replaced whatever was in state — if a
    // tree hydrator is already registered (some feature holds a
    // TreeInterest lease), re-register it so it reads the fresh set right
    // away rather than waiting for the next reconnect. If nothing holds
    // interest yet, [_hydrateTree] reads `_state.expandedPaths` at CALL
    // time, not at registration time, so whichever feature registers it
    // first still restores this set — nothing here is lost by skipping the
    // send.
    if (hasTreeInterest) {
      session.hydrateCheckout(checkoutId, _treeHydratorKey, _hydrateTree);
    }
  }

  /// Expands or collapses [path].
  ///
  /// Expanding is deliberately NOT cached — every call sends a fresh
  /// `file:tree:children:request`, even when [FileNode.childrenLoaded] is
  /// already true. Git-ignored content is never live-watched, so a
  /// collapse-then-expand is the tree's only per-directory refresh gesture
  /// (D2 in docs/file-tree-lazy-expansion-spec.md) — an early return on
  /// `childrenLoaded` here would remove it. Existing children stay on
  /// screen for the round trip; see [_handleChildrenMessage].
  Future<void> toggleExpanded(String path) async {
    final expanded = Set<String>.from(_state.expandedPaths);
    final expanding = !expanded.remove(path);
    if (expanding) expanded.add(path);

    final root = _state.root;
    if (root != null && !expanding) {
      // A collapse leaves `children` as stale leftovers on purpose — see
      // FileNode.childrenLoaded's doc — so only the flags move here.
      final newRoot = _updateAt(
        root,
        path,
        (dir) => _rebuild(dir, childrenLoaded: false, childrenLoading: false),
      );
      _setState(_state.copyWith(root: newRoot, expandedPaths: expanded));
    } else {
      _setState(_state.copyWith(expandedPaths: expanded));
    }

    // The pending mark rides [_fetchChildrenChunked] rather than being
    // stamped here, so every path that asks for a listing gets one.
    if (expanding) {
      await _fetchChildrenChunked([path]);
    }
  }

  /// Expands [path] and every ancestor directory so it is visible in the
  /// tree, fetching each newly-expanded directory's children so the chain
  /// actually renders rather than sitting on stale or empty content — unlike
  /// [toggleExpanded]'s single directory, nothing else will ever ask for
  /// these. Used to reveal a folder a terminal link pointed at, which —
  /// unlike a file — has no `selectedFilePath` of its own to make it visible.
  Future<void> revealDirectory(String path) async {
    final segments = path.split('/').where((s) => s.isNotEmpty);
    final expanded = Set<String>.from(_state.expandedPaths);
    final newlyExpanded = <String>[];
    var acc = '';
    for (final segment in segments) {
      acc = acc.isEmpty ? segment : '$acc/$segment';
      if (expanded.add(acc)) newlyExpanded.add(acc);
    }
    _setState(_state.copyWith(expandedPaths: expanded));
    await _fetchChildrenChunked(newlyExpanded);
  }

  /// Resolves a path a terminal program printed (an OSC 8 `file://` hyperlink
  /// target, absolute or relative) against this checkout, returning its
  /// checkout-relative form — or a null [FileResolvePathResultMessage.relPath]
  /// when it doesn't resolve inside this checkout. Only the bridge can answer
  /// this: the app never learns the checkout's absolute root (see
  /// `docs/architecture.md`), so it cannot relativize the path itself.
  Future<FileResolvePathResultMessage> resolveTerminalPath(String rawPath) {
    final requestId = const Uuid().v4();
    final pending = session.newPending<FileResolvePathResultMessage>(
      timeout: const Duration(seconds: 8),
      onAbandon: () => _pendingResolves.remove(requestId),
    );
    _pendingResolves[requestId] = pending;
    session.sendForCheckout(
      checkoutId,
      createAbMessage('file:resolve-path', {
        'projectId': projectId,
        'requestId': requestId,
        'path': rawPath,
      }),
    );
    return pending.future;
  }

  void selectFile(String path, {int? searchLine, String? searchQuery}) {
    // Fire here, not in requestFileContent — the latter is a shared chokepoint
    // also hit by session-restore, fragment recovery, git "view file", and
    // refresh, none of which is a user opening a file from the explorer.
    session.analytics?.track(AnalyticsEvents.fileOpened);
    final expandedWithAncestors = _expandedWithAncestorsOf(path);
    final newlyExpanded = expandedWithAncestors.difference(
      _state.expandedPaths,
    );
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
        expandedPaths: expandedWithAncestors,
      ),
    );
    // Register (fires now if established) rather than sending inline — see
    // [_hydrateSelectedFile]. Re-registering under the same key supersedes, so
    // opening a new file replaces the prior file's hydrator.
    session.hydrateCheckout(checkoutId, 'file:selected', _hydrateSelectedFile);
    if (newlyExpanded.isNotEmpty) {
      // Fire-and-forget, unlike [revealDirectory]'s await: this method has
      // many synchronous callers (search results, git "view file", terminal
      // links) and opening the file itself must not wait on the tree's own
      // catch-up. The newly-expanded ancestor rows show their existing
      // (possibly stale or empty) content until this lands, same as any
      // other expand.
      detached(
        'FileService',
        'list ancestors of a selected file',
        () => _fetchChildrenChunked(newlyExpanded),
      );
    }
  }

  /// Ancestor directories of [path], folded into the current expanded set —
  /// mirrors [revealDirectory] but for a FILE selection (a terminal link, a
  /// search result, git's "view file", …), none of which otherwise touches
  /// [FileTreeState.expandedPaths]. Without this the tree can select a file
  /// deep inside collapsed folders and show nothing, since [FileTreeView]
  /// only walks into a directory that is in the expanded set.
  Set<String> _expandedWithAncestorsOf(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length <= 1) return _state.expandedPaths;
    final expanded = Set<String>.from(_state.expandedPaths);
    var acc = '';
    for (final segment in segments.sublist(0, segments.length - 1)) {
      acc = acc.isEmpty ? segment : '$acc/$segment';
      expanded.add(acc);
    }
    return expanded;
  }

  void requestFileContent(String path) {
    session.sendForCheckout(
      checkoutId,
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

  /// Opens the attachment-preview overlay on a project-relative [path].
  ///
  /// Deliberately NOT [selectFile]: a preview must leave the Files tab's own
  /// selection (and its persisted preference) untouched, and it is not a
  /// user-opened file, so it files no `fileOpened` analytics event.
  void openPreview(String path, {String? displayName}) {
    _setState(
      _state.copyWith(
        preview: PreviewPaneState(
          path: path,
          displayName: displayName,
          isLoading: true,
        ),
      ),
    );
    // Registered, not sent inline, for the same reason as [_hydrateSelectedFile]
    // — a preview opened during a session-down window would otherwise strand
    // the overlay on its spinner forever.
    session.hydrateCheckout(checkoutId, 'file:preview', _hydratePreview);
  }

  void closePreview() {
    if (!_state.preview.isOpen) return;
    _setState(_state.copyWith(preview: PreviewPaneState.empty));
  }

  /// Tier-3 hydrator for the preview overlay. Reads the path from `_state` so a
  /// re-register always pulls whatever is CURRENTLY open, and no-ops once the
  /// overlay is closed — unregistered on [deactivate] and [dispose].
  Future<void> _hydratePreview() async {
    if (_disposed) return;
    final path = _state.preview.path;
    if (path == null) return;
    requestFileContent(path);
  }

  void requestFullTree() {
    final root = _state.root;
    if (root != null) {
      _listingSeq.clear();
      _setState(_state.copyWith(root: _clearAllLoaded(root)));
    }
    // Deliberately claims nothing, unlike [_pullTree]: this is the user
    // asking for the tree to be rebuilt from disk, and `file:tree:unchanged`
    // would answer that refresh by doing visibly nothing. Keeps
    // expandedPaths, unlike the old whole-tree push this replaced — a lazy
    // tree can no longer leave a folder's stale children on screen forever,
    // so there is nothing left for a wipe to protect against, and folding
    // every open folder on every manual refresh would cost the user their
    // place in the tree for nothing.
    detached('FileService', 'full tree refresh', () async {
      await _requestTree();
      await _fetchChildrenChunked(_state.expandedPaths);
    });
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
    session.unhydrateCheckout(checkoutId, 'file:selected');
  }

  /// Commit whatever is currently staged, with [message]. Result (success or
  /// error) arrives as git:commit-result and is surfaced via [gitOpFeedback];
  /// the changed-file list refreshes automatically from the bridge's
  /// git:status. Which files land in the commit is decided by prior
  /// [stageFiles]/[unstageFiles] calls, not by this one.
  void commit(String message) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:commit', {
        'projectId': projectId,
        'message': message,
      }),
    );
  }

  /// Discard working-tree changes for [files] (tracked -> restore, untracked ->
  /// clean). Unrecoverable -- callers must confirm first.
  ///
  /// [includeStaged] reverts each path all the way to HEAD instead, dropping
  /// its staged content too; without it a fully staged file survives untouched
  /// (the bridge restores the worktree FROM the index). Every Discard/Revert
  /// affordance in the UI passes it — the flag exists so an older bridge, which
  /// ignores it, still does the narrower thing rather than misfiring.
  void discard(List<String> files, {bool includeStaged = false}) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:discard', {
        'projectId': projectId,
        'files': files,
        if (includeStaged) 'includeStaged': true,
      }),
    );
  }

  /// Stage [files] (`git add`) so they're included in the next [commit].
  void stageFiles(List<String> files) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:stage', {'projectId': projectId, 'files': files}),
    );
  }

  /// Unstage [files] (`git reset`) — working tree untouched.
  void unstageFiles(List<String> files) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:unstage', {'projectId': projectId, 'files': files}),
    );
  }

  /// Push the current branch, or publish it when it has no upstream. Never a
  /// force push — a rejected push comes back as a [GitSyncFailure] for the
  /// agent to reconcile rather than being forced through.
  void push() => _sync(GitSyncOp.push);

  /// Fast-forward the current branch onto its upstream. A diverged branch
  /// changes nothing and reports [GitSyncFailureKind.diverged].
  void pull() => _sync(GitSyncOp.pull);

  void _sync(GitSyncOp op) {
    if (_state.git.syncing != null) return;
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(syncing: op, clearSyncFailure: true),
      ),
    );
    // Tier-2 one-shot, the same shape as [requestDiff]: a send dropped in a
    // keyless relay window, or a bridge too old to know the verb, replies
    // never — and without this the two buttons stay disabled for the life of
    // the session.
    _syncLatch?.settle();
    final latch = _syncLatch = ReplyLatch();
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:sync', {'projectId': projectId, 'op': op.name}),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitSyncTimeout).catchError((_) {
        if (_disposed || _syncLatch != latch) return;
        _syncLatch = null;
        _setState(
          _state.copyWith(git: _state.git.copyWith(clearSyncing: true)),
        );
        _emitOpFeedback('${op.label} timed out');
      }),
    );
  }

  /// Re-read how the branch stands against its upstream.
  ///
  /// [probeRemote] additionally asks the REMOTE, which costs a network round
  /// trip — so it is reserved for an explicit user action, never for the
  /// hydrator, which would turn every reconnect into one.
  void refreshSyncState({bool probeRemote = false}) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:sync-status', {
        'projectId': projectId,
        if (probeRemote) 'probeRemote': true,
      }),
    );
  }

  Future<void> _hydrateSyncState() async {
    if (_disposed) return;
    refreshSyncState();
  }

  void requestDiff(String path) {
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          diffPath: path,
          diffLoading: true,
          clearViewing: true,
          // A prior commit diff for the same path must not linger: the reply
          // handler keys on diffCommitSha being unset to accept this one.
          clearDiffCommitSha: true,
        ),
      ),
    );
    // Tier-2 one-shot: bound git:diff on wall-clock so a send dropped before any
    // frame arrives clears diffLoading. Guarded on diffPath so a superseding
    // diff (or a navigate-away) can't have its spinner cleared by a stale
    // timeout. The frag-abort backstop still handles mid-transfer aborts.
    _diffLatch?.settle();
    final latch = _diffLatch = ReplyLatch();
    session.sendForCheckout(
      checkoutId,
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

  /// Commits fetched per `git:log` page — the History tab's scroll-triggered
  /// [loadMoreHistory] asks for another page of this size once the list is
  /// within reach of its end.
  static const historyPageSize = 50;

  bool _historyRequested = false;

  /// Claims the FIRST-ever history load for this service's lifetime,
  /// returning true only on that one call. `GitPanel` calls this on every
  /// build once its data is ready — cheaply and safely, since it is a plain
  /// bool flip, not a state notification — and defers the actual
  /// [loadHistory] send to outside build() only when it wins the claim. That
  /// split is what makes the trigger immune to a build() that fires more than
  /// once before the resulting `loadingMore` state change is reflected back:
  /// without it, each such build would kick off its own `git:log` send and
  /// its own 15s reply timeout, and only the LAST would ever be tracked (or
  /// answered), leaving the earlier ones as orphaned pending timers.
  bool claimHistoryLoad() {
    if (_historyRequested) return false;
    _historyRequested = true;
    return true;
  }

  bool _stashesRequested = false;

  /// Claims the first-ever stash load for this service's lifetime — same
  /// contract as [claimHistoryLoad], and for the same reason: `GitPanel`
  /// calls this on every build, and only the winning call may fire the
  /// `git:stash-list` send.
  bool claimStashLoad() {
    if (_stashesRequested) return false;
    _stashesRequested = true;
    return true;
  }

  /// Fetch every stash in the repository. Called once when the Git tab first
  /// mounts (via [claimStashLoad]); the agent pushes a fresh list itself after
  /// every pop and drop, since the list is the only honest record of what is
  /// left — see [GitPaneState.stashes].
  void loadStashes() {
    // Registered on the first ask rather than in the constructor, for the same
    // reason history is not hydrated at all: a FileService exists whether or
    // not the Git panel is ever opened. Once the panel HAS asked, the list has
    // to survive a reconnect — [claimStashLoad] is one-shot for the service's
    // lifetime and nothing else ever re-reads it, so the banner would go on
    // offering a stash the agent popped while the socket was down.
    // Registering IS the first ask — a hydrator fires immediately when the
    // session is already established and on the next establishment otherwise,
    // so a separate send here would only double it. Re-registering under the
    // same key supersedes, so repeat calls are free.
    session.hydrateCheckout(checkoutId, _stashHydratorKey, _hydrateStashes);
  }

  static const _stashHydratorKey = 'git:stash-list';

  Future<void> _hydrateStashes() => session.sendForCheckout(
    checkoutId,
    createAbMessage('git:stash-list', {'projectId': projectId}),
  );

  /// Reapplies [ref] and drops it on success — the Git panel banner's
  /// "Restore". Callers on a branch OTHER than the one the stash was made on
  /// should switch first: a pop is a 3-way merge against the stash's own
  /// base, and popping onto an unrelated branch invites a conflict that has
  /// nothing to do with what the user asked for.
  void restoreStash(String ref) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:stash-pop', {'projectId': projectId, 'ref': ref}),
    );
  }

  /// Discards [ref] permanently — the Git panel banner's "Discard". Callers
  /// must confirm first.
  void dropStash(String ref) {
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:stash-drop', {'projectId': projectId, 'ref': ref}),
    );
  }

  /// History tab: fetch the first page of commits, replacing whatever was
  /// loaded before. Called once when the tab is first shown.
  void loadHistory() {
    _historyLatch?.settle();
    final latch = _historyLatch = ReplyLatch();
    // Keeps whatever is already loaded on screen. `_handleGitLogResult`
    // replaces the list wholesale for a `skip == 0` page, so clearing it here
    // buys nothing and costs the caller its view: `_HistoryList` renders its
    // full-pane spinner for exactly "initialLoad with no commits", which on a
    // pull-to-refresh tore the RefreshIndicator out from under the gesture
    // that started it and dropped the scroll position with it. Only a list
    // that is genuinely empty is an initial load.
    final history = _state.git.history;
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: history.copyWith(
            loadingMore: true,
            initialLoad: history.commits.isEmpty,
            hasMore: true,
            clearError: true,
          ),
        ),
      ),
    );
    _requestLogPage(skip: 0, latch: latch);
  }

  /// History tab: fetch the next page, appending to what is already loaded.
  /// No-op while a page is already loading or none remain — the scroll
  /// listener that drives this has no other way to avoid firing repeatedly
  /// near the bottom of the list.
  void loadMoreHistory() {
    final history = _state.git.history;
    if (history.loadingMore || !history.hasMore) return;
    _historyLatch?.settle();
    final latch = _historyLatch = ReplyLatch();
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(history: history.copyWith(loadingMore: true)),
      ),
    );
    _requestLogPage(skip: history.commits.length, latch: latch);
  }

  void _requestLogPage({required int skip, required ReplyLatch latch}) {
    _pendingLogSkip = skip;
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:log', {
        'projectId': projectId,
        'skip': skip,
        'limit': historyPageSize,
      }),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed || _historyLatch != latch) return;
        _historyLatch = null;
        _pendingLogSkip = null;
        _setState(
          _state.copyWith(
            git: _state.git.copyWith(
              history: _state.git.history.copyWith(
                loadingMore: false,
                initialLoad: false,
                error: 'Loading history timed out — no response from the agent',
              ),
            ),
          ),
        );
      }),
    );
  }

  /// History tab: expand a commit's file list, fetching it on first expand —
  /// [GitHistoryState.filesBySha] is a cache the toggle never re-fetches once
  /// populated — or collapse it back up. More than one commit can stay
  /// expanded at once; see [collapseAllHistory] for the bulk fold.
  void toggleCommitExpanded(String sha) {
    final history = _state.git.history;
    final expanded = Set<String>.from(history.expandedShas);
    final expanding = !expanded.remove(sha);
    if (expanding) expanded.add(sha);
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: history.copyWith(expandedShas: expanded),
        ),
      ),
    );
    if (expanding &&
        !history.filesBySha.containsKey(sha) &&
        !history.filesLoadingShas.contains(sha)) {
      _requestCommitFiles(sha);
    }
  }

  /// History tab: re-fetch a commit's file list after [_requestCommitFiles]
  /// failed — the commit is already expanded (that's why an error row is on
  /// screen), so retrying is a plain re-fetch rather than another toggle.
  void retryCommitFiles(String sha) => _requestCommitFiles(sha);

  void _requestCommitFiles(String sha) {
    final history = _state.git.history;
    final loading = Set<String>.from(history.filesLoadingShas)..add(sha);
    final errors = Map<String, String>.from(history.filesErrorBySha)
      ..remove(sha);
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: history.copyWith(
            filesLoadingShas: loading,
            filesErrorBySha: errors,
          ),
        ),
      ),
    );
    _commitFilesLatches.remove(sha)?.settle();
    final latch = ReplyLatch();
    _commitFilesLatches[sha] = latch;
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:commit-files', {'projectId': projectId, 'sha': sha}),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed || _commitFilesLatches[sha] != latch) return;
        _commitFilesLatches.remove(sha);
        final stillLoading = Set<String>.from(
          _state.git.history.filesLoadingShas,
        )..remove(sha);
        final withError = Map<String, String>.from(
          _state.git.history.filesErrorBySha,
        )..[sha] = 'Loading files timed out — no response from the agent';
        _setState(
          _state.copyWith(
            git: _state.git.copyWith(
              history: _state.git.history.copyWith(
                filesLoadingShas: stillLoading,
                filesErrorBySha: withError,
              ),
            ),
          ),
        );
      }),
    );
  }

  /// History tab: fold every expanded commit's file list shut without
  /// dropping the cached files — the same "Collapse All" the Changes tab's
  /// folder toggle offers, applied to expanded commits instead of folders.
  void collapseAllHistory() {
    final history = _state.git.history;
    if (history.expandedShas.isEmpty) return;
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          history: history.copyWith(expandedShas: const {}),
        ),
      ),
    );
  }

  /// Fold the whole History section shut in the side-by-side layout, or
  /// reopen it — see [GitPaneState.historyCollapsed].
  void toggleHistoryCollapsed() {
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          historyCollapsed: !_state.git.historyCollapsed,
        ),
      ),
    );
  }

  /// History tab: open one file's diff within [sha] — the same viewer
  /// [requestDiff] opens for the working tree, distinguished on screen by
  /// [GitPaneState.diffCommitSha].
  void requestCommitDiff(String sha, String path) {
    _setState(
      _state.copyWith(
        git: _state.git.copyWith(
          diffPath: path,
          diffCommitSha: sha,
          diffLoading: true,
          clearViewing: true,
        ),
      ),
    );
    _diffLatch?.settle();
    final latch = _diffLatch = ReplyLatch();
    session.sendForCheckout(
      checkoutId,
      createAbMessage('git:commit-diff', {
        'projectId': projectId,
        'sha': sha,
        'path': path,
      }),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed ||
            _diffLatch != latch ||
            _state.git.diffPath != path ||
            _state.git.diffCommitSha != sha) {
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

  /// Git pane: fold a changed-files folder shut, or open it again.
  ///
  /// Separate from [toggleExpanded], which owns the Files tab's tree — see
  /// [GitPaneState.collapsedPaths] for why the two states are not shared.
  void toggleGitFolder(String path) {
    final collapsed = Set<String>.from(_state.git.collapsedPaths);
    if (!collapsed.remove(path)) collapsed.add(path);
    _setState(
      _state.copyWith(git: _state.git.copyWith(collapsedPaths: collapsed)),
    );
  }

  /// Git pane: fold every folder in [paths] shut at once, or (with an empty
  /// set) open them all. The caller supplies the folder list because only the
  /// rendered tree knows which directories the current change set produced.
  void setGitCollapsedFolders(Set<String> paths) {
    _setState(_state.copyWith(git: _state.git.copyWith(collapsedPaths: paths)));
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
    _syncLatch?.settle();
    _syncLatch = null;
    _historyLatch?.settle();
    _historyLatch = null;
    _pendingLogSkip = null;
    for (final latch in _commitFilesLatches.values) {
      latch.settle();
    }
    _commitFilesLatches.clear();
    _listingSeq.clear();
    final resolves = _pendingResolves.values.toList();
    _pendingResolves.clear();
    for (final pending in resolves) {
      pending.fail(StateError('FileService disposed'));
    }
    session.unhydrateCheckout(checkoutId, 'file:selected');
    session.unhydrateCheckout(checkoutId, 'file:preview');
    session.unhydrateCheckout(checkoutId, _treeHydratorKey);
    session.unhydrateCheckout(checkoutId, _syncHydratorKey);
    session.unhydrateCheckout(checkoutId, _stashHydratorKey);
    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _resumeSub?.cancel();
    _resumeSub = null;
    await _stateController.close();
  }
}
