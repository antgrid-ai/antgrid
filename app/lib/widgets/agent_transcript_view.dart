import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart'
    show SelectionArea, SelectableRegionState;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:collection/collection.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_menu.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_composer_send_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_kbd.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../models/agent_event.dart';
import '../models/capability_catalog.dart';
import '../models/file_tree_models.dart';
import '../providers/agent_transport.dart';
import '../providers/capability_catalog.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../services/agent_session_service.dart';
import '../services/attach_hydration.dart';
import '../services/clipboard_image_reader.dart';
import '../services/upload_service.dart';
import 'attachment_preview_dialog.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../util/image_thumbnail.dart';
import '../utils/platform_utils.dart';
import 'transcript/background_tasks_strip.dart';
import 'transcript/composer/composer_attachments.dart';
import 'transcript/composer/composer_controller.dart';
import 'transcript/composer/rich_composer.dart';
import 'transcript/composer_selectors.dart';
import 'transcript/context_meter.dart';
import 'transcript/file_mention_suggestions.dart';
import 'transcript/pending_prompt_panel.dart';
import 'transcript/rows/compaction_divider.dart';
import 'transcript/rows/error_banner.dart';
import 'transcript/rows/message_row.dart';
import 'transcript/rows/plan_checklist.dart';
import 'transcript/rows/prompt_marker_row.dart';
import 'transcript/rows/reasoning_block.dart';
import 'transcript/rows/subtask_row.dart';
import 'transcript/rows/tool_call_card.dart';
import 'transcript/rows/turn_fold_row.dart';
import 'transcript/rows/unknown_row.dart';
import 'transcript/rows/usage_footer_row.dart';
import 'transcript/rows/working_row.dart';
import 'transcript/selection/transcript_clipboard.dart';
import 'transcript/selection/transcript_selection_scope.dart';
import 'transcript/slash_suggestions.dart';
import 'transcript/transcript_rows.dart';

/// Structured-agent transcript, rendered as a flat list of [TranscriptRow]s
/// derived from [AgentSessionState] (see [deriveRows]). Sends prompts back
/// through [AgentSessionService].
class AgentTranscriptView extends ConsumerStatefulWidget {
  final String sessionId;

  const AgentTranscriptView({super.key, required this.sessionId});

  @override
  ConsumerState<AgentTranscriptView> createState() =>
      _AgentTranscriptViewState();
}

class _AgentTranscriptViewState extends ConsumerState<AgentTranscriptView> {
  final _input = ComposerController();
  final _scroll = ScrollController();
  final _panelFocus = FocusNode();
  final _selection = TranscriptSelectionController();
  final _expandedTurnIds = <String>{};
  final _expandedItemIds = <String>{};
  final _expandedReasoningIds = <String>{};
  final _dismissedErrorTurnIds = <String>{};

  /// Latest version whose update chip the user dismissed for this view. A newer
  /// `latest` re-surfaces the chip (the value won't match).
  String? _dismissedUpdateVersion;
  bool _following = true;
  bool _newSinceScroll = false;
  int _lastRowCount = 0;

  // RichComposer installs the key handler on this node; _onComposerKey runs
  // as its prelude so suggestion nav keeps priority over smart-enter send.
  final _inputFocus = FocusNode();

  // Interaction state for the composer surface's border (default → strong on
  // hover → accent while the prompt has focus) — the same "armed instrument"
  // contract as the New Session composer.
  bool _composerHovered = false;
  bool _inputFocused = false;
  List<AgentCapabilityCommand> _suggestions = const [];
  int _suggestionIndex = 0;
  bool _suggestionsDismissed = false;
  List<FileMention> _mentionSuggestions = const [];
  int _mentionIndex = 0;
  bool _mentionDismissed = false;
  // Identity-cached flatten of the synced tree (same pattern as _cachedRows):
  // the root object is replaced wholesale on every tree update, so identity
  // is the correct (and cheapest) invalidation key.
  List<FileMention> _mentionCandidates = const [];
  FileNode? _mentionCacheRoot;
  AgentCapabilities? _capabilities;
  // Signature of the last catalog persisted for this session, so the post-frame
  // remember runs once per distinct catalog rather than on every rebuild.
  String? _lastCachedSig;
  final List<ComposerAttachment> _attachments = [];

  // The service the transcript hydrator was registered on, pinned so dispose can
  // deregister the exact instance without ref.watch (illegal there). See
  // AgentSessionService.stopHydrating. Also the key [_armHydration] compares
  // against to detect a service swap.
  AgentSessionService? _hydratedOn;
  bool _armScheduled = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _inputFocus.addListener(_onInputFocusChanged);
  }

  // Load prior turns for this session, re-arming on every SERVICE SWAP rather
  // than once at mount. AgentPanel keys this view by session id, so a fresh
  // State mounts for whichever chat session becomes active — but the mount
  // instant is NOT when the service is necessarily resolved, and it is not the
  // only time the session this view must hydrate against changes:
  //
  //  - A reconnect (session-takeover → "take back", a supervisor block the user
  //    retried) invalidates `projectSessionProvider`, which builds a WHOLE new
  //    ProjectSession: new transport, new AgentSessionService, empty transcript.
  //    Its predecessor's hydrator dies with its transport.
  //  - Around that swap `sessionsStateProvider` serves the OUTGOING service's
  //    list for a frame (Riverpod retains the previous AsyncData while it
  //    re-subscribes — see freshSessionsStateProvider), so the view can mount,
  //    or remount, before the incoming session has resolved.
  //
  // A mount-only hydrate loses both: the pull is either never registered or
  // registered on a service whose transport is already dead, and the user is
  // left on "Send a message to start" with the history intact on the bridge
  // until they leave the session and reopen it. Keying off the resolved service
  // identity is what makes every one of those paths converge here.
  void _armHydration() {
    final svc = serviceWhenReady(ref, agentSessionServiceProvider);
    if (svc == null || identical(svc, _hydratedOn) || _armScheduled) return;
    _armScheduled = true;
    // Post-frame, not inline: hydrateIfNeeded publishes state synchronously, and
    // emitting into a provider mid-build is illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _armScheduled = false;
      if (!mounted) return;
      final entry = ref.read(activeSessionProvider);
      if (entry == null || entry.id != widget.sessionId) return;
      final armed = hydrateAttachedChatIfNeeded(ref, entry);
      if (armed == null || identical(armed, _hydratedOn)) return;
      _hydratedOn?.stopHydrating(widget.sessionId);
      _hydratedOn = armed;
    });
  }

  void _onInputFocusChanged() {
    if (_inputFocus.hasFocus == _inputFocused) return;
    setState(() => _inputFocused = _inputFocus.hasFocus);
  }

  // deriveRows is pure over (state, expansion/dismiss sets). Cache its result so
  // setState-driven rebuilds (scroll, toggles) don't re-derive+re-allocate the
  // whole row list. `_ephemeralVersion` bumps on every mutation of the four sets
  // below (all routed through _toggle / the dismiss handler), so a stale cache
  // can't outlive a set change; a new state object from the stream also misses.
  List<TranscriptRow>? _cachedRows;
  AgentSessionState? _cachedState;
  int _ephemeralVersion = 0;
  int _cachedVersion = -1;

  @override
  void dispose() {
    // Stop re-pulling this session's transcript on every reconnect now that its
    // view is gone — the view is keyed per session id, so this fires exactly
    // when the user navigates off / switches to another session.
    _hydratedOn?.stopHydrating(widget.sessionId);
    _input.removeListener(_onInputChanged);
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  // A chronological prompt marker points at the always-pinned panel; tapping it
  // scrolls the newest content into view and pulls focus to the panel's field.
  void _focusPendingPanel() {
    _jumpToLatest();
    _panelFocus.requestFocus();
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    setState(() {
      _following = true;
      _newSinceScroll = false;
    });
  }

  // Capture the scroll offset before a fold/reasoning/card toggle rebuilds
  // the list with a different total extent, then restore it post-frame so
  // expanding a row above the viewport doesn't yank the scroll position.
  // Only while the user has scrolled away — stick-to-bottom already owns
  // the following case and this would otherwise fight it.
  void _toggleWithScrollStability(VoidCallback toggle) {
    final before = _scroll.hasClients ? _scroll.offset : null;
    setState(toggle);
    if (before == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && !_following) {
        _scroll.jumpTo(before.clamp(0, _scroll.position.maxScrollExtent));
      }
    });
  }

  // True when there is something to send and nothing still in flight. Shared by
  // the send button's enabled state and _submit so the two never drift.
  bool get _canSubmit =>
      !_attachments.any((a) => a.status == AttachmentStatus.uploading) &&
      (!_input.isEmpty ||
          _attachments.any((a) => a.status == AttachmentStatus.done));

  void _submit() {
    if (!_canSubmit) return;
    final donePaths = _attachments
        .where((a) => a.status == AttachmentStatus.done)
        .map((a) => a.path!)
        .toList();
    // Guard on plain-text emptiness (what the hint reflects), not the markdown
    // encoding: an empty heading/list/quote block looks empty but still encodes
    // its bare marker ('#', '-', '>'), which must never be sent — so drop the
    // markdown entirely when the plain text is empty and send only the paths.
    final text = _input.isEmpty ? '' : _input.toMarkdown();
    if (text.isEmpty && donePaths.isEmpty) return;
    // serviceWhenReady, not ref.read of the throwing façade — a bare read throws
    // synchronously if the session is still resolving.
    final service = serviceWhenReady(ref, agentSessionServiceProvider);
    if (service == null) return;
    final r = resolveSubmission(text, _capabilities);
    service.prompt(
      widget.sessionId,
      appendAttachmentPaths(r.text, donePaths),
      commandId: r.commandId,
    );
    _input.clear();
    // Clear only the attachments that were actually sent. Errored ones stay so
    // the user still sees them (and their retry/remove affordance) rather than
    // having a failed upload silently vanish on send.
    setState(
      () => _attachments.removeWhere((a) => a.status == AttachmentStatus.done),
    );
  }

  // Best-effort size gate from the file's stat, so a huge pick is rejected
  // before it's read into memory. If length() isn't supported (returns < 0 or
  // throws on some platforms), fall back to the post-read byte-length check.
  Future<bool> _isOverCap(XFile file) async {
    try {
      final len = await file.length();
      return len > UploadService.kMaxUploadBytes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickAndAttach() async {
    final XFile? file;
    try {
      file = await openFile();
    } catch (_) {
      if (mounted) showAbSnackBar(context, 'Could not open the file picker');
      return;
    }
    if (file == null) return;
    // Reject oversized files by their stat length before reading — readAsBytes
    // would otherwise pull the whole (potentially multi-GB) file into memory
    // just to fail the cap.
    if (await _isOverCap(file)) {
      if (mounted) {
        showAbSnackBar(
          context,
          uploadErrorText(const UploadException('TOO_LARGE', ''), file.name),
        );
      }
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      if (mounted) showAbSnackBar(context, uploadErrorText(e, file.name));
      return;
    }
    await _attachBytes(fileName: file.name, bytes: bytes);
  }

  /// Shared tail of every attach route (file picker, clipboard paste): caps,
  /// shows the chip, then uploads.
  Future<void> _attachBytes({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    if (!mounted) return;
    if (bytes.length > UploadService.kMaxUploadBytes) {
      showAbSnackBar(
        context,
        uploadErrorText(const UploadException('TOO_LARGE', ''), fileName),
      );
      return;
    }
    final attachment = ComposerAttachment(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );
    setState(() => _attachments.add(attachment));
    // Decoded from the payload we still hold — _runUpload releases it on
    // success. Detached so the chip and the upload both start immediately
    // rather than queueing behind an image decode.
    detached('AgentTranscriptView', 'decode attachment thumbnail', () async {
      final thumbnail = await decodeThumbnail(bytes);
      if (thumbnail == null || !mounted) return;
      setState(() => attachment.thumbnail = thumbnail);
    });
    await _runUpload(attachment);
  }

  /// Fleather hands the pasted image over from a void callback, so the upload
  /// is started detached rather than left to reject unobserved.
  void _onImagePasted(PastedImage image) {
    detached('AgentTranscriptView', 'attach pasted image', () async {
      await _attachBytes(
        fileName: image.fileName,
        bytes: image.bytes,
        mimeType: image.mimeType,
      );
    });
  }

  void _onPreviewAttachment(ComposerAttachment attachment) {
    final relPath = attachment.relPath;
    if (relPath == null) return;
    // The container, not the ref: this chip is disposed by a project switch,
    // and the dialog outlives the tap.
    final container = ref.container;
    detached('AgentTranscriptView', 'preview attachment', () async {
      await showAttachmentPreview(
        context,
        container,
        relPath: relPath,
        displayName: attachment.fileName,
      );
    });
  }

  Future<void> _runUpload(ComposerAttachment attachment) async {
    final service = serviceWhenReady(ref, uploadServiceProvider);
    if (service == null) {
      setState(() => _attachments.remove(attachment));
      if (mounted) {
        showAbSnackBar(
          context,
          uploadErrorText(
            const UploadException('OFFLINE', ''),
            attachment.fileName,
          ),
        );
      }
      return;
    }
    setState(() {
      attachment.status = AttachmentStatus.uploading;
      attachment.progress = 0;
    });
    try {
      final result = await service.upload(
        fileName: attachment.fileName,
        bytes: attachment.bytes!,
        mimeType: attachment.mimeType,
        onProgress: (sent, total) {
          if (mounted) setState(() => attachment.progress = sent / total);
        },
      );
      if (!mounted) return;
      setState(() {
        attachment
          ..status = AttachmentStatus.done
          ..path = result.path
          ..relPath = result.relPath
          ..previewMimeType = result.mimeType
          ..bytes = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => attachment.status = AttachmentStatus.error);
      showAbSnackBar(context, uploadErrorText(e, attachment.fileName));
    }
  }

  AgentSessionService? _service() =>
      serviceWhenReady(ref, agentSessionServiceProvider);

  void _retryHydration() {
    final svc = _service();
    _hydratedOn = svc ?? _hydratedOn;
    final f = svc?.hydrateIfNeeded(widget.sessionId);
    if (f != null) unawaited(f);
  }

  // Confirm the upgrade, then run it in-app via the gated agent:update verb:
  // the agent quiesces the running codex session(s) to release the machine-wide
  // binary lock, runs `codex update`, and restarts them. Progress and outcome
  // surface through AgentSessionState.updating / updateResult (see _UpdateBanner).
  Future<void> _showUpdateDialog(
    BuildContext context,
    AgentUpdateAvailable upd,
  ) async {
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: '${upd.tool} update available',
      body:
          'You have ${upd.tool} ${upd.installed}; ${upd.latest} is available. '
          'Antgrid will pause the running ${upd.tool} session(s) on the agent '
          'machine, run the update, and restart them. This replaces the '
          'machine-wide ${upd.tool} binary.',
      confirmLabel: 'Update now',
      cancelLabel: 'Later',
    );
    if (!confirmed) return;
    _service()?.requestUpdate(widget.sessionId, upd.tool);
  }

  void _toggle(Set<String> set, String id) {
    set.contains(id) ? set.remove(id) : set.add(id);
    _ephemeralVersion++;
  }

  void _onInputChanged() {
    // Any edit re-arms a previously Esc-dismissed panel and re-derives below.
    // One flag per panel: Esc on one must not suppress the other.
    setState(() {
      _suggestionsDismissed = false;
      _mentionDismissed = false;
    });
  }

  List<AgentCapabilityCommand> _deriveSuggestions() {
    final caps = _capabilities;
    if (caps == null || _suggestionsDismissed) return const [];
    final line = _input.firstLine;
    if (line == null || !line.text.startsWith('/')) return const [];
    // A formatted line (heading/list/code) is content, not a command.
    if (!_input.caretLineIsPlain) return const [];
    final firstSpace = line.text.indexOf(' ');
    final tokenEnd = firstSpace < 0 ? line.text.length : firstSpace;
    // Only while the caret is inside the command token — once the user moves
    // into the args, the popup would fight normal typing.
    if (line.caret > tokenEnd) return const [];
    return filterSlashCommands(caps.commands, line.text.substring(1, tokenEnd));
  }

  List<FileMention> _deriveMentionSuggestions() {
    if (_mentionDismissed || _mentionCandidates.isEmpty) return const [];
    final token = _input.mentionToken;
    if (token == null) return const [];
    return filterFileMentions(_mentionCandidates, token.query);
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // At most one panel is non-empty (mention derivation is gated on the
    // slash list being empty), so first-non-empty routing is exact.
    if (_suggestions.isNotEmpty) {
      return _panelNav(
        event,
        count: _suggestions.length,
        index: _suggestionIndex,
        onIndex: (i) => setState(() => _suggestionIndex = i),
        onAccept: () => _acceptSuggestion(_suggestions[_suggestionIndex]),
        onDismiss: () => setState(() => _suggestionsDismissed = true),
      );
    }
    if (_mentionSuggestions.isNotEmpty) {
      return _panelNav(
        event,
        count: _mentionSuggestions.length,
        index: _mentionIndex,
        onIndex: (i) => setState(() => _mentionIndex = i),
        onAccept: () => _acceptMention(_mentionSuggestions[_mentionIndex]),
        onDismiss: () => setState(() => _mentionDismissed = true),
      );
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _panelNav(
    KeyEvent event, {
    required int count,
    required int index,
    required ValueChanged<int> onIndex,
    required VoidCallback onAccept,
    required VoidCallback onDismiss,
  }) {
    final key = event.logicalKey;
    // Full length, not capped at the panel's visible-row max: the panel
    // windows its display around selectedIndex, so nav must be able to reach
    // every match.
    if (key == LogicalKeyboardKey.arrowDown) {
      onIndex((index + 1) % count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      onIndex((index - 1 + count) % count);
      return KeyEventResult.handled;
    }
    // numpadEnter parity: smart-enter treats it as a send key too, so an open
    // suggestion must consume it the same as main enter (else it falls
    // through and sends the partial token).
    if (key == LogicalKeyboardKey.tab ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      onAccept();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _acceptSuggestion(AgentCapabilityCommand c) {
    _input.acceptCommand(c.name);
    setState(() => _suggestionIndex = 0);
  }

  void _acceptMention(FileMention m) {
    _input.acceptMention(m.isDir ? '${m.path}/' : m.path);
    setState(() => _mentionIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    _armHydration();
    final stateAsync = ref.watch(agentSessionStateProvider(widget.sessionId));
    // `.value` (nullable), not `.value ?? const AgentSessionState()`: the
    // latter collapses AsyncValue.loading into the empty state, flashing
    // "Send a message to start" before a real session's history has loaded.
    final state = stateAsync.value;

    Widget body;
    if (state == null) {
      body = stateAsync.hasError
          ? Center(
              child: Text(
                'Could not load this session',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textMuted,
                ),
              ),
            )
          : const AbLoading();
    } else {
      if (!identical(state, _cachedState) ||
          _cachedVersion != _ephemeralVersion ||
          _cachedRows == null) {
        _cachedRows = deriveRows(state, expandedTurnIds: _expandedTurnIds)
            .where(
              (r) =>
                  r is! ErrorRowData ||
                  !_dismissedErrorTurnIds.contains(r.turnId),
            )
            .toList();
        _cachedState = state;
        _cachedVersion = _ephemeralVersion;
      }
      final rows = _cachedRows!;
      final backgroundItemIds = <String>{
        for (final t
            in state.backgroundTasks?.tasks ?? const <AgentBackgroundTask>[])
          if (t.itemId != null) t.itemId!,
      };

      // Stick-to-bottom: jump after the frame that laid out any new rows, but
      // only while the user hasn't scrolled away to read earlier history. Only
      // register the callback when following so we don't schedule a closure
      // every build; the inner guard still re-checks in case state changed.
      if (_following) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_following && _scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }

      // Read, not setState: this runs during build, and the pill below reads
      // the same field in this build pass. `_lastRowCount` is the prior
      // build's count, so growth here means new rows arrived while scrolled
      // away.
      if (!_following && rows.length > _lastRowCount) {
        _newSinceScroll = true;
      }
      _lastRowCount = rows.length;

      // `loading` is checked INSIDE the empty branch, not ahead of it: a
      // transcript refetch (the turn-end hydration retry) runs against a session
      // that already has rows, and a spinner must never replace history the user
      // is reading. It only ever stands in for an empty body.
      body = rows.isEmpty
          ? (state.loading
                ? const AbLoading()
                : state.hydrationFailed
                ? _HydrationRetryRow(onRetry: _retryHydration)
                : Center(
                    child: Text(
                      'Send a message to start',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontMd,
                        color: context.antgrid.textMuted,
                      ),
                    ),
                  ))
          : TranscriptSelectionScope(
              controller: _selection,
              // TODO(flutter#161010): pass selectionHeightStyle: BoxHeightStyle.strut
              // once SelectionArea exposes it (PR flutter#186802) for uniform-height
              // selection rects across mixed font sizes. Until then the painted
              // highlight is hardcoded to BoxHeightStyle.tight (per-glyph metrics),
              // so inline code / headings highlight at different heights than body
              // text; markdown_body.dart size-matches inline code to body as a
              // partial mitigation.
              // Ctrl/Cmd+C hits SelectableRegion's built-in copy action, which
              // writes text/plain only and never reaches our resolver. That
              // action is registered via Action.overridable, so overriding
              // CopySelectionTextIntent from this parent Actions routes the
              // keyboard copy through the same rich path as the menu's Copy.
              child: Actions(
                actions: <Type, Action<Intent>>{
                  CopySelectionTextIntent:
                      CallbackAction<CopySelectionTextIntent>(
                        onInvoke: (_) {
                          _selection
                              .copy(CopyKind.rich)
                              .catchError(
                                (Object e) => AbLog.error(
                                  'AgentTranscript',
                                  'copy failed',
                                  fields: {'error': '$e'},
                                ),
                              );
                          return null;
                        },
                      ),
                },
                // SelectionArea must wrap ONLY the list, never the overlay
                // chrome: a widget (e.g. the jump-to-latest chip) appearing
                // inside the SelectionArea mid-selection re-registers a
                // selectable with its delegate, and the framework then replays
                // the drag-time screen coordinates against the new scroll
                // offset — visibly re-anchoring an active selection onto the
                // wrong text (StaticSelectionContainerDelegate.didChangeSelectables).
                child: Stack(
                  children: [
                    SelectionArea(
                      onSelectionChanged: (content) =>
                          _selection.onSelectionChanged(content?.plainText),
                      contextMenuBuilder: _selectionMenu,
                      child: NotificationListener<UserScrollNotification>(
                        onNotification: (notification) {
                          if (notification.direction ==
                              ScrollDirection.forward) {
                            if (_following) setState(() => _following = false);
                          } else if (_scroll.hasClients &&
                              _scroll.position.maxScrollExtent -
                                      _scroll.position.pixels <=
                                  40) {
                            if (!_following || _newSinceScroll) {
                              setState(() {
                                _following = true;
                                _newSinceScroll = false;
                              });
                            }
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                            vertical: AbTokens.space8,
                          ),
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final row = rows[i];
                            return KeyedSubtree(
                              key: ValueKey(row.rowKey),
                              child: _buildRow(row, i, backgroundItemIds),
                            );
                          },
                        ),
                      ),
                    ),
                    if (!_following)
                      Positioned(
                        bottom: AbTokens.space8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: AbChip.label(
                            label: _newSinceScroll
                                ? '• jump to latest'
                                : 'jump to latest',
                            color: context.antgrid.accent,
                            onTap: _jumpToLatest,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
    }

    final effectiveState = state ?? const AgentSessionState();
    final isRunning = effectiveState.isRunning;
    final live = effectiveState.capabilities;

    // Cache-key this session's catalog by (focused machine, tool). Custom-command
    // sessions (no tool) have no stable catalog — skip them entirely.
    final toolKey = ref
        .watch(freshSessionsStateProvider)
        ?.sessions
        .firstWhereOrNull((s) => s.id == widget.sessionId)
        ?.tool;
    CapabilityCatalog? cachedCatalog;
    if (toolKey != null && toolKey.isNotEmpty) {
      final cacheKey = capabilityCacheKey(
        capabilitySourceKey(ref.watch(selectedTargetProvider)),
        toolKey,
      );
      ref.read(capabilityCatalogProvider.notifier).ensureHydrated(cacheKey);
      cachedCatalog = ref.watch(capabilityCatalogProvider)[cacheKey];

      // Persist the LIVE catalog (never the cache-overlaid merge below, which
      // would re-write stale data as if fresh) as the seed for the next session
      // of this tool. Only the FOCUSED session's transcript view runs this —
      // that's enough (one catalog per tool) and is why the write lives here,
      // not in the Riverpod-unaware AgentSessionService. Persist post-frame —
      // mutating a provider during build throws — and only when the catalog
      // changed (models, modes, or commands).
      if (live != null && live.ready && live.models.isNotEmpty) {
        final catalog = CapabilityCatalog.fromCapabilities(live);
        final sig = '$cacheKey:${jsonEncode(catalog.toJson())}';
        if (sig != _lastCachedSig) {
          _lastCachedSig = sig;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref
                  .read(capabilityCatalogProvider.notifier)
                  .remember(cacheKey, catalog);
            }
          });
        }
      }
    }
    // The composer — pills, slash-command suggestions, AND submit resolution —
    // all read this cache-merged view, so a cold session offers cached models
    // and commands during the discovery gap. Live overrides once it is ready.
    _capabilities = resolveComposerCapabilities(
      live: live,
      cached: cachedCatalog,
    );
    _suggestions = _deriveSuggestions();
    if (_suggestionIndex >= _suggestions.length) _suggestionIndex = 0;
    // `.select` on the root shields this widget from unrelated FileTreeState
    // churn (git statuses, pane state, expansion sets).
    final treeRoot = ref.watch(
      fileTreeStateProvider.select((s) => s.value?.root),
    );
    if (!identical(treeRoot, _mentionCacheRoot)) {
      _mentionCacheRoot = treeRoot;
      _mentionCandidates = flattenFileTree(treeRoot);
    }
    // Slash wins; the two triggers are naturally mutually exclusive (a slash
    // token is whitespace-free on line 0, so no '@'-after-whitespace fits it).
    _mentionSuggestions = _suggestions.isNotEmpty
        ? const []
        : _deriveMentionSuggestions();
    if (_mentionIndex >= _mentionSuggestions.length) _mentionIndex = 0;
    final displayCaps = _capabilities;

    // The update strip surfaces three mutually-exclusive states (precedence
    // updating > result > available inside _UpdateBanner): an in-flight update,
    // its outcome, or a dismissible "newer CLI available" advisory.
    final availableUpdate = switch (effectiveState.updateAvailable) {
      final upd? when upd.latest != _dismissedUpdateVersion => upd,
      _ => null,
    };
    final showUpdateBanner =
        effectiveState.updating ||
        effectiveState.updateResult != null ||
        availableUpdate != null;
    // Which agent a Retry would update. Everything that could name it, in
    // descending confidence: the failed run itself, the advisory that offered
    // the update, then the session's own tool. All three null (a custom launch
    // command) disables the button — firing an update for an agent nobody named
    // is worse than not offering one.
    final retryTool =
        effectiveState.updateResult?.tool ??
        availableUpdate?.tool ??
        (toolKey != null && toolKey.isNotEmpty ? toolKey : null);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AbTokens.transcriptMaxWidth,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: body),
            BackgroundTasksStrip(
              tasks: effectiveState.backgroundTasks?.tasks ?? const [],
              onStop: (task) =>
                  _service()?.stopTask(widget.sessionId, task.taskId),
            ),
            if (showUpdateBanner)
              _UpdateBanner(
                updating: effectiveState.updating,
                result: effectiveState.updateResult,
                available: availableUpdate,
                onUpdate: availableUpdate == null
                    ? null
                    : () => _showUpdateDialog(context, availableUpdate),
                onRetry: retryTool == null
                    ? null
                    : () =>
                          _service()?.requestUpdate(widget.sessionId, retryTool),
                onDismissResult: () =>
                    _service()?.dismissUpdateResult(widget.sessionId),
                onDismissAvailable: availableUpdate == null
                    ? null
                    : () => setState(
                        () => _dismissedUpdateVersion = availableUpdate.latest,
                      ),
              ),
            PendingPromptPanel(
              permissions: effectiveState.pendingPermissions,
              questions: effectiveState.pendingQuestions,
              inputFocusNode: _panelFocus,
              onPermission: (request, optionId) =>
                  _service()?.resolvePermission(
                    request.sessionId,
                    request.permissionId,
                    optionId,
                  ),
              onQuestion: (question, answer) => _service()?.resolveQuestion(
                question.sessionId,
                question.questionId,
                answer,
              ),
            ),
            SlashSuggestions(
              commands: _suggestions,
              selectedIndex: _suggestionIndex,
              onPick: _acceptSuggestion,
            ),
            FileMentionSuggestions(
              entries: _mentionSuggestions,
              selectedIndex: _mentionIndex,
              onPick: _acceptMention,
            ),
            Padding(
              padding: const EdgeInsets.all(AbTokens.space8),
              child: _composerSurface(
                context,
                isRunning: isRunning,
                capabilities: displayCaps,
                usage: effectiveState.usage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The composer as one "armed instrument" surface — the same interaction
  /// contract as the New Session composer (new_session_composer.dart): a
  /// single bordered box whose border tracks hover/focus, a ❯ shell-prompt
  /// marker beside the field, and the controls (model/effort/mode pills,
  /// context meter, Enter hint, send/stop key) docked inside it.
  Widget _composerSurface(
    BuildContext context, {
    required bool isRunning,
    required AgentCapabilities? capabilities,
    required AgentUsage? usage,
  }) {
    final p = context.antgrid;
    final borderColor = _inputFocused
        ? p.accent
        : _composerHovered
        ? p.borderStrong
        : p.borderDefault;

    return MouseRegion(
      onEnter: (_) => setState(() => _composerHovered = true),
      onExit: (_) => setState(() => _composerHovered = false),
      child: AnimatedContainer(
        duration: AbTokens.motionDefault,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: AbTokens.borderRadius8,
          color: p.bgSurface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space12,
                AbTokens.space4,
                AbTokens.space12,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Shell-prompt marker: the terminal-native "type here"
                  // affordance. Top inset aligns it with the editor's first
                  // text line (space8 editor padding + space4 block spacing
                  // + 2px font-metric compensation, as in new_session_composer).
                  Padding(
                    padding: const EdgeInsets.only(top: AbTokens.space14),
                    child: Text(
                      '❯',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontMd,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  Expanded(
                    child: RichComposer(
                      controller: _input,
                      focusNode: _inputFocus,
                      hintText: 'Send a message…',
                      keyEventPrelude: _onComposerKey,
                      onSend: _submit,
                      onImagePasted: _onImagePasted,
                    ),
                  ),
                ],
              ),
            ),
            ComposerAttachmentChips(
              attachments: _attachments,
              onRemove: (a) => setState(() => _attachments.remove(a)),
              onRetry: _runUpload,
              onPreview: _onPreviewAttachment,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space10,
                AbTokens.space4,
                AbTokens.space10,
                AbTokens.space10,
              ),
              child: Row(
                children: [
                  AbIconButton(
                    icon: AbIcons.attach,
                    tooltip: 'Attach file',
                    onTap: _pickAndAttach,
                  ),
                  if (usage != null) ...[
                    const SizedBox(width: AbTokens.space6),
                    ContextMeter(usage: usage),
                  ],
                  const SizedBox(width: AbTokens.space6),
                  Expanded(
                    child: capabilities != null
                        ? ComposerSelectors(
                            capabilities: capabilities,
                            onSetConfig: (key, value) => _service()?.setConfig(
                              widget.sessionId,
                              key,
                              value,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // Hardware-Enter hint — desktop only. Fades rather than
                  // pops so the control row doesn't reflow while typing.
                  if (!isMobilePlatform) ...[
                    const SizedBox(width: AbTokens.space8),
                    AnimatedOpacity(
                      duration: AbTokens.motionDefault,
                      opacity: _inputFocused && !_input.isEmpty ? 1 : 0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AbKbd('⏎'),
                          const SizedBox(width: AbTokens.space6),
                          Text(
                            'to send',
                            style: AbTokens.sansStyle(
                              fontSize: AbTokens.fontXs,
                              color: p.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(width: AbTokens.space10),
                  isRunning
                      ? ComposerSendButton(
                          icon: AbIcons.stop,
                          color: p.error,
                          onTap: () => _service()?.cancel(widget.sessionId),
                        )
                      : ComposerSendButton(onTap: _canSubmit ? _submit : null),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionMenu(BuildContext context, SelectableRegionState state) {
    void run(CopyKind kind) {
      // Fire-and-forget, but never let a clipboard write reject unobserved: an
      // unhandled async error crashes the debug zone and tells the user nothing.
      _selection.copy(kind).catchError(
        (Object e) => AbLog.error('AgentTranscript', 'copy failed', fields: {'error': '$e'}),
      );
      state.hideToolbar();
    }

    // Design-system menu positioned at the selection anchor, in place of
    // Material's AdaptiveTextSelectionToolbar (raw Material chrome + fonts).
    return CustomSingleChildLayout(
      delegate: _SelectionMenuLayout(state.contextMenuAnchors.primaryAnchor),
      child: AbMenu(
        items: [
          AbMenuItem(label: 'Copy', onTap: () => run(CopyKind.rich)),
          AbMenuItem(
            label: 'Copy as Plain Text',
            onTap: () => run(CopyKind.plain),
          ),
          AbMenuItem(
            label: 'Copy as Markdown',
            onTap: () => run(CopyKind.markdown),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    TranscriptRow row,
    int rowIndex,
    Set<String> backgroundItemIds,
  ) => switch (row) {
    MessageRowData r => MessageRow(
      data: r,
      rowIndex: rowIndex,
      onRevert: r.isUser
          ? () => _service()?.revert(
              widget.sessionId,
              turnId: r.turnId,
              itemId: r.item.itemId,
              messageId: r.item.revertMessageId,
              partId: r.item.revertPartId,
            )
          : null,
    ),
    ReasoningRowData r => ReasoningBlock(
      data: r,
      rowIndex: rowIndex,
      expanded: _expandedReasoningIds.contains(r.item.itemId),
      onToggle: () => _toggleWithScrollStability(
        () => _toggle(_expandedReasoningIds, r.item.itemId),
      ),
    ),
    ToolCallRowData r => ToolCallCard(
      data: r,
      rowIndex: rowIndex,
      expanded: _expandedItemIds.contains(r.item.itemId),
      isBackground: backgroundItemIds.contains(r.item.itemId),
      onToggle: () => _toggleWithScrollStability(
        () => _toggle(_expandedItemIds, r.item.itemId),
      ),
    ),
    PlanRowData r => PlanChecklist(data: r, rowIndex: rowIndex),
    SubtaskRowData r => SubtaskRow(data: r),
    CompactionRowData r => CompactionDivider(data: r),
    UnknownRowData r => UnknownRow(data: r),
    TurnFoldRowData r => TurnFoldRow(
      data: r,
      expanded: _expandedTurnIds.contains(r.turnId),
      onToggle: () =>
          _toggleWithScrollStability(() => _toggle(_expandedTurnIds, r.turnId)),
    ),
    WorkingRowData r => WorkingRow(
      data: r,
      onStop: () => _service()?.cancel(widget.sessionId),
    ),
    ErrorRowData r => ErrorBanner(
      data: r,
      onDismiss: () => setState(() {
        _dismissedErrorTurnIds.add(r.turnId);
        _ephemeralVersion++;
      }),
    ),
    PromptMarkerRowData r => PromptMarkerRow(
      data: r,
      onTap: _focusPendingPanel,
    ),
    UsageRowData r => Padding(
      padding: const EdgeInsets.only(
        left: AbTokens.space16,
        right: AbTokens.space8,
        top: AbTokens.space2,
        bottom: AbTokens.space8,
      ),
      child: UsageFooterRow(usage: r.usage),
    ),
  };
}

class _HydrationRetryRow extends StatelessWidget {
  final VoidCallback onRetry;

  const _HydrationRetryRow({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Couldn't load earlier messages",
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
          AbButton(label: 'Retry', onTap: onRetry),
        ],
      ),
    );
  }
}

/// Positions the selection copy-menu near the selection's primary anchor:
/// above it when there's room, otherwise below, clamped into the viewport.
class _SelectionMenuLayout extends SingleChildLayoutDelegate {
  const _SelectionMenuLayout(this.anchor);

  final Offset anchor;
  static const double _pad = AbTokens.space8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = anchor.dx - childSize.width / 2;
    // Anchor sits at the top edge of the selection — prefer above, drop below
    // when the menu would clip off the top.
    var y = anchor.dy - childSize.height - _pad;
    if (y < _pad) y = anchor.dy + _pad;
    x = x.clamp(_pad, math.max(_pad, size.width - childSize.width - _pad));
    y = y.clamp(_pad, math.max(_pad, size.height - childSize.height - _pad));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_SelectionMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

/// Update strip above the composer. Renders one of three mutually-exclusive
/// states (precedence updating > result > available):
///   • updating — in-flight `agent:update` (pulsing dot, not dismissible);
///   • result   — the outcome: success confirmation, or failure + Retry;
///   • available — advisory "newer CLI available" chip; tap opens the confirm.
/// The close button dismisses the result or the advisory version (see
/// `_dismissedUpdateVersion`). 1px top border, no elevation — per Design Rules.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.updating,
    required this.result,
    required this.available,
    required this.onUpdate,
    required this.onRetry,
    required this.onDismissResult,
    required this.onDismissAvailable,
  });

  final bool updating;
  final AgentUpdateResult? result;
  final AgentUpdateAvailable? available;

  /// Opens the confirm for [available]; null when there is nothing to offer.
  final VoidCallback? onUpdate;

  /// Re-runs the failed update; null when nothing names the agent it would
  /// update, which renders Retry disabled rather than guessing one.
  final VoidCallback? onRetry;
  final VoidCallback onDismissResult;

  /// Dismisses the [available] advisory; null when there is none.
  final VoidCallback? onDismissAvailable;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      decoration: BoxDecoration(
        color: c.bgElevated,
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: _content(c),
    );
  }

  Widget _content(AbColors c) {
    if (updating) {
      return Row(
        children: [
          const AbLoadingDot(size: 10),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              'Updating… pausing and restarting the session.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: c.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    final res = result;
    if (res != null) {
      final ok = res.ok;
      final label = ok
          ? (res.installed != null
                ? '${res.tool} updated to ${res.installed}.'
                : '${res.tool} updated.')
          : '${res.tool} update failed.';
      return Row(
        children: [
          AbIcon(
            ok ? AbIcons.check : AbIcons.warning,
            size: 14,
            color: ok ? c.success : c.error,
          ),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: c.textSecondary,
              ),
            ),
          ),
          if (!ok) ...[
            AbButton(label: 'Retry', onTap: onRetry, compact: true),
            const SizedBox(width: AbTokens.space4),
          ],
          AbIconButton(
            icon: AbIcons.close,
            onTap: onDismissResult,
            tooltip: 'Dismiss',
          ),
        ],
      );
    }

    final info = available;
    if (info == null) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: AbChip.label(
            label:
                '${info.tool} ${info.latest} available — you have ${info.installed}',
            color: c.accent,
            onTap: onUpdate,
          ),
        ),
        AbIconButton(
          icon: AbIcons.close,
          onTap: onDismissAvailable,
          tooltip: 'Dismiss',
        ),
      ],
    );
  }
}
