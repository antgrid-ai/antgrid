import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/theme_presets.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../models/command_models.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../services/command_service.dart';
import '../util/detached.dart';
import 'send_capture_to_agent.dart';
import 'send_to_agent_button.dart';
import 'send_to_agent_comment.dart';

/// What "Send to Agent" hands over. A trimmed run says so up front: the dropped
/// head is often where a failing build printed its first error, and an agent
/// given a mid-run start would read it as the whole run.
@visibleForTesting
String commandOutputForAgent(CommandOutput output) =>
    output.trimmed ? '[earlier output trimmed]\n${output.text}' : output.text;

/// The running/last project command, pinned to the bottom of the terminal
/// Stack.
///
/// It shares that edge with `HandlerEscalationOverlay`, which is opaque and
/// full-width too; which of the two paints over the other is decided at their
/// mount in `AgentPanel`, and this one is on top because it is the only one of
/// the two the user can dismiss.
class CommandOutputOverlay extends ConsumerStatefulWidget {
  const CommandOutputOverlay({super.key});

  @override
  ConsumerState<CommandOutputOverlay> createState() =>
      _CommandOutputOverlayState();
}

class _CommandOutputOverlayState extends ConsumerState<CommandOutputOverlay> {
  bool _expanded = true;
  Timer? _autoHideTimer;
  final ScrollController _scrollController = ScrollController();
  bool _scrollPending = false;
  bool _hasOutputSelection = false;

  /// Anchors the follow-up comment popover under [SendToAgentButton] instead
  /// of the window's centre — see [showSendToAgentComment]'s `anchorLink`.
  final LayerLink _sendToAgentLink = LayerLink();

  /// The project and checkout [_lastState] came from. [commandStateProvider]
  /// follows focus, so states from different checkouts must not be compared.
  (String?, String)? _stateSource;
  CommandState? _lastState;

  /// The focused project's [CommandService], or null while its session is
  /// (re-)resolving. Every use below fires from a timer or a tap, where the
  /// throwing façade would land outside any `build()` as an unhandled error.
  CommandService? get _commandService =>
      focusedCheckoutServiceOrNull(ref.container, (s) => s.commandService);

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onCommandStateChanged(AsyncValue<CommandState> value) {
    // The re-subscribe after a focus switch passes through loading with the
    // previous checkout's state still attached; it says nothing new.
    if (value.isLoading) return;
    final next = value.value ?? const CommandState();
    final source = (
      ref.read(selectedRegistrationIdProvider),
      ref.read(focusedCheckoutIdProvider),
    );
    final prev = source == _stateSource ? _lastState : null;
    _stateSource = source;
    _lastState = next;

    final prevExec = prev?.current;
    final current = next.current;

    if (current == null) {
      _autoHideTimer?.cancel();
      return;
    }

    if (prevExec == null || prevExec.output != current.output) {
      _autoHideTimer?.cancel();
      setState(() => _expanded = true);
    }

    if (current.status == CommandStatus.success &&
        prevExec?.status == CommandStatus.running) {
      _autoHideTimer?.cancel();
      setState(() => _expanded = false);
      // The checkout that finished, not whichever is focused in three seconds.
      final owner = _commandService;
      _autoHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) owner?.dismiss();
      });
    }

    if (current.status == CommandStatus.failed &&
        prevExec?.status == CommandStatus.running) {
      _autoHideTimer?.cancel();
      setState(() => _expanded = true);
    }
  }

  void _toggleExpanded() {
    _autoHideTimer?.cancel();
    setState(() => _expanded = !_expanded);
  }

  void _dismiss() {
    _autoHideTimer?.cancel();
    _commandService?.dismiss();
  }

  void _rerun() {
    final current = ref.read(commandStateProvider).value?.current;
    if (current == null) return;
    _autoHideTimer?.cancel();
    _commandService?.runCommand(current.commandName);
  }

  /// Routed through [sendCaptureToAgent] — see the same doc on
  /// `TerminalViewWrapper._onSendToAgent` for why this no longer resolves a
  /// terminal service and sends by hand.
  Future<void> _sendTextToAgent(String text) async {
    final current = ref.read(commandStateProvider).value?.current;
    if (current == null) return;

    final sourceLabel = '[from command: ${current.commandName}]';
    final message = await showSendToAgentComment(
      context: context,
      selectedText: text,
      sourceLabel: sourceLabel,
      anchorLink: _sendToAgentLink,
    );

    if (message == null || !mounted) return;
    await sendCaptureToAgent(
      context: context,
      container: ref.container,
      text: message,
    );
  }

  void _sendFullOutputToAgent() {
    final current = ref.read(commandStateProvider).value?.current;
    if (current == null) return;
    final output = current.output;
    if (output.isEmpty) return;
    final outputText = commandOutputForAgent(output);
    detached(
      'CommandOutputOverlay',
      'send to agent failed',
      () => _sendTextToAgent(outputText),
    );
  }

  void _scheduleScroll() {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(commandStateProvider, (_, next) => _onCommandStateChanged(next));

    final current = ref.watch(commandStateProvider).value?.current;
    if (current == null) return const SizedBox.shrink();

    final agentTab = ref.watch(agentTerminalProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = switch (current.status) {
      CommandStatus.running => Colors.amber,
      CommandStatus.success => const Color(0xFF4CAF50),
      CommandStatus.failed => const Color(0xFFE05050),
      CommandStatus.idle => Colors.grey,
    };

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        height: _expanded ? 280 : 48,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          border: Border(top: BorderSide(color: borderColor, width: 2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          children: [
            GestureDetector(
              onTap: _toggleExpanded,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space16,
                ),
                child: Row(
                  children: [
                    _buildStatusIcon(current.status, borderColor),
                    const SizedBox(width: AbTokens.space8),
                    _buildTitle(current, borderColor),
                    if (current.exitCode != null) ...[
                      const SizedBox(width: AbTokens.space8),
                      _buildExitCodeBadge(current.exitCode!, colorScheme),
                    ],
                    const Spacer(),
                    ..._buildActions(current, colorScheme, agentTab != null),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A10),
                    border: Border(
                      top: BorderSide(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.2,
                        ),
                      ),
                    ),
                  ),
                  child: ListenableBuilder(
                    listenable: current.output,
                    builder: (context, _) {
                      _scheduleScroll();
                      final output = current.output;
                      // Built here, not hoisted: monoStyle reads the mutable
                      // AbTokens.activeWeightOffset.
                      final outputStyle = AbTokens.monoStyle(
                        fontSize: AbTokens.fontMd,
                        height: 1.4,
                        color: const Color(0xFFD4D4D4),
                      );
                      final showSendButton =
                          _hasOutputSelection && agentTab != null;
                      return Stack(
                        children: [
                          SingleChildScrollView(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(AbTokens.space12),
                            child: SelectionArea(
                              onSelectionChanged: (value) {
                                final hasSelection =
                                    value != null && value.plainText.isNotEmpty;
                                if (hasSelection != _hasOutputSelection) {
                                  setState(
                                    () => _hasOutputSelection = hasSelection,
                                  );
                                }
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Output past the cap is gone, and a view
                                  // that starts mid-run without saying so reads
                                  // as the whole run. The fixed default palette
                                  // tints it because this surface is the same
                                  // dark under every theme; the light theme's
                                  // textMuted is under AA on it.
                                  if (output.trimmed)
                                    SelectionContainer.disabled(
                                      key: const ValueKey<String>('trimmed'),
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: AbTokens.space6,
                                        ),
                                        child: Text(
                                          'Earlier output trimmed',
                                          style: AbTokens.sansStyle(
                                            fontSize: AbTokens.fontXs,
                                            color: kDefaultPalette.textMuted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  _OutputBlocks(
                                    key: const ValueKey<String>('blocks'),
                                    output: output,
                                    style: outputStyle,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (showSendButton)
                            SendToAgentButton(
                              link: _sendToAgentLink,
                              onPressed: () {
                                // Extract selected text at press time
                                // SelectionArea doesn't expose text programmatically,
                                // so we send the full output as fallback
                                _sendFullOutputToAgent();
                              },
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(CommandStatus status, Color color) {
    return switch (status) {
      CommandStatus.running => AbLoadingDot(size: 14, color: color),
      CommandStatus.success => Icon(Icons.check_circle, size: 18, color: color),
      CommandStatus.failed => Icon(Icons.cancel, size: 18, color: color),
      CommandStatus.idle => Icon(Icons.circle_outlined, size: 18, color: color),
    };
  }

  Widget _buildTitle(CommandExecution current, Color color) {
    final prefix = switch (current.status) {
      CommandStatus.running => 'Running',
      CommandStatus.success => 'Success',
      CommandStatus.failed => 'Failed',
      CommandStatus.idle => '',
    };
    return Text(
      '$prefix: ${current.commandName}',
      style: AbTokens.sansStyle(
        fontWeight: FontWeight.w600,
        fontSize: AbTokens.fontMd,
        color: color,
      ),
    );
  }

  Widget _buildExitCodeBadge(int exitCode, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space6,
        vertical: 1,
      ), // 1px badge inset
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'exit $exitCode',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  List<Widget> _buildActions(
    CommandExecution current,
    ColorScheme colorScheme,
    bool hasAgentTerminal,
  ) {
    return [
      if (current.status == CommandStatus.failed && hasAgentTerminal) ...[
        _actionButton(
          icon: Icons.upload_outlined,
          label: 'Send to Agent',
          color: const Color(0xFF80B0FF),
          backgroundColor: const Color(0xFF1A2A3A),
          onTap: _sendFullOutputToAgent,
        ),
        const SizedBox(width: AbTokens.space6),
      ],
      if (current.status == CommandStatus.success ||
          current.status == CommandStatus.failed) ...[
        _actionButton(
          icon: Icons.replay,
          label: 'Re-run',
          color: const Color(0xFF63D297),
          backgroundColor: const Color(0xFF1A3A2A),
          onTap: _rerun,
        ),
        const SizedBox(width: AbTokens.space6),
      ],
      AbIconButton(icon: AbIcons.close, onTap: _dismiss, tooltip: 'Close'),
    ];
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color backgroundColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AbTokens.space4),
            Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputBlocks extends StatefulWidget {
  const _OutputBlocks({super.key, required this.output, required this.style});

  final CommandOutput output;
  final TextStyle style;

  @override
  State<_OutputBlocks> createState() => _OutputBlocksState();
}

class _OutputBlocksState extends State<_OutputBlocks> {
  final _BlockLineJoiner _joiner = _BlockLineJoiner();
  final List<Widget> _blockWidgets = [];
  int _blockWidgetsFirstSeq = 0;

  @override
  void didUpdateWidget(covariant _OutputBlocks oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new run's blocks reuse the same absolute numbers, so a stale cache
    // would show the previous run.
    if (oldWidget.output != widget.output || oldWidget.style != widget.style) {
      _blockWidgets.clear();
    }
  }

  @override
  void dispose() {
    // SelectionContainer never disposes the delegate it is handed.
    _joiner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final output = widget.output;
    final blocks = output.blocks;
    final first = output.firstBlockSeq;
    // Sealed blocks never change, so each block's Text is built once and
    // handed back as the identical instance. The element tree skips an
    // identical widget outright, which keeps a flush's rebuild to the tail
    // however many blocks are kept.
    final stale = (first - _blockWidgetsFirstSeq).clamp(
      0,
      _blockWidgets.length,
    );
    _blockWidgets.removeRange(0, stale);
    _blockWidgetsFirstSeq = first;
    for (var i = _blockWidgets.length; i < blocks.length; i++) {
      // Keyed by absolute number, so dropping the oldest blocks leaves every
      // survivor's paragraph laid out. Matched by position, each survivor
      // would be handed its neighbour's text.
      _blockWidgets.add(
        Text(blocks[i], key: ValueKey<int>(first + i), style: widget.style),
      );
    }
    return SelectionContainer(
      delegate: _joiner,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ..._blockWidgets,
          Text(
            output.isEmpty ? ' ' : output.tail,
            key: const ValueKey<String>('tail'),
            style: widget.style,
          ),
        ],
      ),
    );
  }
}

/// Flutter concatenates sibling paragraphs' selections with nothing between
/// them (`MultiSelectableSelectionContainerDelegate.getSelectedContent`), so
/// without this a copy spanning two blocks would run two lines together. Every
/// block boundary used up exactly one line break. A boundary that used up
/// '\r\n' copies as '\n', because the delegate knows a boundary is there, not
/// which terminator it was.
class _BlockLineJoiner extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent content)
          content.plainText,
    ];
    if (parts.isEmpty) return null;
    return SelectedContent(plainText: parts.join('\n'));
  }
}
