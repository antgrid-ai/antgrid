import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';

import '../../design/ab_icons.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_composer_send_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_kbd.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/agent_event.dart';
import '../../models/capability_catalog.dart';
import '../../models/file_tree_models.dart';
import '../../providers/agent_transport.dart';
import '../../providers/capability_catalog.dart';
import '../../providers/chat_composer_drafts.dart';
import '../../providers/composer_handoff.dart';
import '../../providers/demo_mode.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../services/agent_session_service.dart';
import '../../services/clipboard_image_reader.dart';
import '../../services/file_service.dart';
import '../../services/upload_service.dart';
import '../../util/detached.dart';
import '../../util/image_thumbnail.dart';
import '../../utils/platform_utils.dart';
import '../attachment_preview_dialog.dart';
import 'composer/composer_attachments.dart';
import 'composer/composer_controller.dart';
import 'composer/rich_composer.dart';
import 'composer_selectors.dart';
import 'context_meter.dart';
import 'file_mention_suggestions.dart';
import 'slash_suggestions.dart';

/// The transcript's prompt composer: draft, attachments, slash and @-mention
/// suggestions, and the surface chrome around them.
///
/// It owns every piece of state a keystroke touches, so typing rebuilds this
/// subtree and never the transcript list above it. It reads the session's
/// running flag, capabilities and usage itself rather than taking them from the
/// parent for the same reason: a parent that handed them down would have to
/// rebuild to do it.
///
/// Size changes (a draft growing a line, a suggestion panel opening) are
/// announced with a [SizeChangedLayoutNotification] so the transcript can keep
/// its newest row in view.
class TranscriptComposer extends ConsumerStatefulWidget {
  final String sessionId;

  const TranscriptComposer({super.key, required this.sessionId});

  @override
  ConsumerState<TranscriptComposer> createState() => _TranscriptComposerState();
}

class _TranscriptComposerState extends ConsumerState<TranscriptComposer> {
  late final ComposerController _input;

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
  // True while a `file:find` this mention token issued is in flight — gates
  // the panel's "Searching…" row so an empty [_mentionSuggestions] mid-fetch
  // never reads as "no matches" (see [_maybeFindMentions]).
  bool _mentionLoading = false;
  // Set from `file:find-result.error` (or a transport failure): a listing the
  // bridge aborted answers with zero entries too, so without it a search that
  // never ran renders as "No matching files".
  String? _mentionError;
  // The query [_maybeFindMentions] last issued a find for, so a listener tick
  // that changed only the caret (not the token text) doesn't restart the
  // debounce and delay every result forever.
  String? _mentionIssuedQuery;
  // Bumped on every issued find; a callback that lands after a newer one has
  // already been issued for a DIFFERENT query drops its result instead of
  // clobbering the fresher one — belt-and-suspenders alongside
  // [FileService.find]'s own supersede-by-requestId.
  int _mentionRequestGen = 0;
  AgentCapabilities? _capabilities;
  // Signature of the last catalog persisted for this session, so the post-frame
  // remember runs once per distinct catalog rather than on every rebuild.
  String? _lastCachedSig;
  // AgentSessionService replaces the capabilities object wholesale on each
  // frame and never mutates one, so the same instance under the same key can
  // only re-derive the signature already held in [_lastCachedSig], and this
  // build runs on every composer keystroke.
  AgentCapabilities? _lastSigCaps;
  String? _lastSigKey;
  final List<ComposerAttachment> _attachments = [];

  late final ChatComposerDrafts _drafts;
  late final ProviderContainer _container;

  /// The exact callback published to [focusAgentInputProvider], held so dispose
  /// retracts ITS OWN and never the next view's — a session flipping to
  /// terminal mode mounts that view before this one is disposed.
  late final VoidCallback _publishedFocusInput = _inputFocus.requestFocus;

  @override
  void initState() {
    super.initState();
    // Pinned, not re-read in dispose: at app teardown the ProviderScope above
    // is disposed before this State is, and reading a provider from a dead
    // container throws.
    _drafts = ref.read(chatComposerDraftsProvider);
    _input = _drafts.forSession(widget.sessionId);
    _input.addListener(_onInputChanged);
    _inputFocus.addListener(_onInputFocusChanged);
    _container = ref.container;
    // Post-frame: publishing writes a provider, which must not happen during
    // initState. Same registration shape as WorkspaceShell's own hooks.
    //
    // Retracted in dispose rather than deactivate, unlike those: this view sits
    // inside the GlobalKey-reparented AgentPanel, so deactivate fires on every
    // desktop panel-mode toggle and would leave the agent unfocusable after one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(focusAgentInputProvider.notifier).set(_publishedFocusInput);
    });
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    // Hands the draft back to the cache, which owns it: an ordinary remount
    // keeps it, and a session retired while this view was on screen is what
    // makes the cache dispose it here rather than under a live editor.
    _drafts.release(widget.sessionId);
    _inputFocus.removeListener(_onInputFocusChanged);
    // try/catch for the app-teardown case the pinned container exists for: the
    // container itself can already be disposed by the time this runs.
    try {
      if (identical(
        _container.read(focusAgentInputProvider),
        _publishedFocusInput,
      )) {
        _container.read(focusAgentInputProvider.notifier).set(null);
      }
    } on Object {
      // Nothing to retract from — the container is gone.
    }
    _inputFocus.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if (_inputFocus.hasFocus == _inputFocused) return;
    setState(() => _inputFocused = _inputFocus.hasFocus);
  }

  AgentSessionService? _service() =>
      serviceWhenReady(ref, agentSessionServiceProvider);

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
    final service = _service();
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
      if (mounted) showAbToast(context, 'Could not open the file picker');
      return;
    }
    if (file == null) return;
    // Reject oversized files by their stat length before reading — readAsBytes
    // would otherwise pull the whole (potentially multi-GB) file into memory
    // just to fail the cap.
    if (await _isOverCap(file)) {
      if (mounted) {
        showAbToast(
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
      if (mounted) showAbToast(context, uploadErrorText(e, file.name));
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
      showAbToast(
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
    detached('TranscriptComposer', 'decode attachment thumbnail', () async {
      final thumbnail = await decodeThumbnail(bytes);
      if (thumbnail == null || !mounted) return;
      setState(() => attachment.thumbnail = thumbnail);
    });
    await _runUpload(attachment);
  }

  /// Takes the one capture parked for the composer (a preview element pick, a
  /// drawing over the live preview) and turns it into an ordinary attachment
  /// plus seeded text — from there it is the user's draft, and nothing sends
  /// until they press send.
  ///
  /// Claimed by clearing the slot FIRST: this runs from a listener that fires
  /// again on any later rebuild, and a handoff left in place would be attached
  /// a second time.
  void _consumeHandoff(ComposerHandoff handoff) {
    ref.read(composerHandoffProvider.notifier).set(null);
    _input.appendText(handoff.text);
    _inputFocus.requestFocus();
    final bytes = handoff.bytes;
    final fileName = handoff.fileName;
    if (bytes == null || fileName == null) return;
    detached('TranscriptComposer', 'attach handed-off capture', () async {
      await _attachBytes(
        fileName: fileName,
        bytes: bytes,
        mimeType: handoff.mimeType,
      );
    });
  }

  /// Fleather hands the pasted image over from a void callback, so the upload
  /// is started detached rather than left to reject unobserved.
  void _onImagePasted(PastedImage image) {
    detached('TranscriptComposer', 'attach pasted image', () async {
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
    detached('TranscriptComposer', 'preview attachment', () async {
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
        showAbToast(
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
      showAbToast(context, uploadErrorText(e, attachment.fileName));
    }
  }

  void _onInputChanged() {
    // Any edit re-arms a previously Esc-dismissed panel and re-derives below.
    // One flag per panel: Esc on one must not suppress the other.
    setState(() {
      _suggestionsDismissed = false;
      _mentionDismissed = false;
    });
    _maybeFindMentions();
  }

  /// Kicks a debounced `file:find` for the active @-mention token, if any.
  /// No-ops when the token's query text hasn't actually changed since the
  /// last issue (a pure caret move re-notifies the composer too) or when no
  /// checkout-scoped [FileService] is resolvable yet.
  void _maybeFindMentions() {
    final token = _input.mentionToken;
    if (token == null) {
      _mentionIssuedQuery = null;
      _mentionError = null;
      return;
    }
    if (_mentionDismissed || token.query == _mentionIssuedQuery) return;
    // Resolved fresh rather than read through `fileServiceProvider`: this runs
    // outside build(), where that façade throws while the focused project's
    // session is unresolved. Both are checkout-scoped.
    final fileService = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.fileService,
    );
    // The watermark records only queries that actually went out. Set above
    // this guard it latched a token the service was still unresolved for, and
    // the equality check then blocked every retry for that exact text.
    if (fileService == null) return;
    _mentionIssuedQuery = token.query;
    final gen = ++_mentionRequestGen;
    setState(() {
      _mentionLoading = true;
      _mentionError = null;
    });
    detached('TranscriptComposer', 'find mention candidates', () async {
      FileFindResultMessage result;
      try {
        // Mentions hand a path to the agent, so ignored files (build
        // output, node_modules) are noise here — unlike the tree's own
        // browse default.
        result = await fileService.find(
          token.query,
          includeIgnored: false,
          kinds: 'both',
        );
      } on FileFindSuperseded {
        // NOT necessarily a keystroke of our own: the file explorer's filter
        // box resolves the same FileService, which keeps one wanted call for
        // the whole service, and both surfaces are mounted at once on
        // desktop. Clearing the watermark too is what lets the next composer
        // notification re-issue for the same token text.
        if (mounted && gen == _mentionRequestGen) {
          setState(() {
            _mentionLoading = false;
            _mentionIssuedQuery = null;
          });
        }
        return;
      } catch (_) {
        if (mounted && gen == _mentionRequestGen) {
          setState(() {
            _mentionLoading = false;
            _mentionError = 'Search failed';
          });
        }
        return;
      }
      if (!mounted || gen != _mentionRequestGen) return;
      setState(() {
        _mentionLoading = false;
        // A killed or timed-out listing answers with zero entries too, so
        // without this the panel says "No matching files" for a search that
        // never ran.
        _mentionError = result.error;
        _mentionSuggestions = [
          for (final e in result.entries) (path: e.path, isDir: e.isDir),
        ];
        if (_mentionIndex >= _mentionSuggestions.length) _mentionIndex = 0;
      });
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
    // `_mentionLoading`, not just a non-empty list: the panel is open and
    // says "Searching…" for the debounce plus a round trip, and an Enter in
    // that window used to fall through to smart-enter and SEND the raw
    // `@token` as literal text with no file attached.
    if (_mentionLoading || _mentionSuggestions.isNotEmpty) {
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
    final navigable = count > 0;
    // Full length, not capped at the panel's visible-row max: the panel
    // windows its display around selectedIndex, so nav must be able to reach
    // every match. An open-but-empty panel (a find still in flight) consumes
    // the key without moving anything — letting it through would move the
    // caret or send the message instead.
    if (key == LogicalKeyboardKey.arrowDown) {
      if (navigable) onIndex((index + 1) % count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (navigable) onIndex((index - 1 + count) % count);
      return KeyEventResult.handled;
    }
    // numpadEnter parity: smart-enter treats it as a send key too, so an open
    // suggestion must consume it the same as main enter (else it falls
    // through and sends the partial token).
    if (key == LogicalKeyboardKey.tab ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (navigable) onAccept();
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
    // Watched, not listened: the capture is parked as a VALUE precisely
    // because this view may not have been mounted when it was made (a session
    // in terminal mode, an expanded workspace panel), so it has to be picked
    // up on the first build that CAN — which a listen-only hook, firing only
    // on change, would sit right through. Post-frame because consuming it
    // writes to a provider and mutates the composer.
    final handoff = ref.watch(composerHandoffProvider);
    if (handoff != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = ref.read(composerHandoffProvider);
        if (pending == null) return;
        _consumeHandoff(pending);
      });
    }

    // Selected, so a streamed delta that changes none of these leaves this
    // subtree alone.
    final stateProvider = agentSessionStateProvider(widget.sessionId);
    final isRunning = ref.watch(
      stateProvider.select((a) => a.value?.isRunning ?? false),
    );
    final live = ref.watch(stateProvider.select((a) => a.value?.capabilities));
    final usage = ref.watch(stateProvider.select((a) => a.value?.usage));

    // Cache-key this session's catalog by (focused machine, tool). Custom-command
    // sessions (no tool) have no stable catalog — skip them entirely.
    final toolKey = ref
        .watch(freshSessionsStateProvider)
        ?.sessions
        .firstWhereOrNull((s) => s.id == widget.sessionId)
        ?.tool;
    CapabilityCatalog? cachedCatalog;
    // The demo's tool is a real one ('claude') and its target keys as local, so
    // this cache entry is the SAME one the user's own local Claude sessions
    // read — writing 'Sample model' into it poisons the real model picker, and
    // reading it back shows the demo a machine's models.
    if (toolKey != null && toolKey.isNotEmpty && !ref.watch(demoModeProvider)) {
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
      if (live != null &&
          live.ready &&
          live.models.isNotEmpty &&
          !(identical(live, _lastSigCaps) && cacheKey == _lastSigKey)) {
        _lastSigCaps = live;
        _lastSigKey = cacheKey;
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
    // Slash wins; the two triggers are naturally mutually exclusive (a slash
    // token is whitespace-free on line 0, so no '@'-after-whitespace fits it).
    // [_mentionSuggestions] itself is populated asynchronously by
    // [_maybeFindMentions] (a `file:find` round trip, not a synced tree read —
    // mentions no longer hold a [TreeInterest] lease at all) — this only
    // clears it when it must not be SHOWN, same discipline as the old
    // synchronous derivation, so a result that lands while still valid is
    // never clobbered by a build it didn't cause.
    final mentionVisible =
        _suggestions.isEmpty &&
        !_mentionDismissed &&
        _input.mentionToken != null;
    if (!mentionVisible) _mentionSuggestions = const [];
    if (_mentionIndex >= _mentionSuggestions.length) _mentionIndex = 0;

    return SizeChangedLayoutNotifier(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SlashSuggestions(
            commands: _suggestions,
            selectedIndex: _suggestionIndex,
            onPick: _acceptSuggestion,
          ),
          FileMentionSuggestions(
            entries: _mentionSuggestions,
            selectedIndex: _mentionIndex,
            onPick: _acceptMention,
            visible: mentionVisible,
            loading: _mentionLoading,
            error: _mentionError,
          ),
          Padding(
            padding: const EdgeInsets.all(AbTokens.space8),
            child: _composerSurface(
              context,
              isRunning: isRunning,
              capabilities: _capabilities,
              usage: usage,
            ),
          ),
        ],
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
}
