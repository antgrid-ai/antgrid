import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../models/command_models.dart';
import '../providers/providers.dart';
import '../services/command_service.dart';
import 'send_to_agent_button.dart';
import 'send_to_agent_comment.dart';

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

  void _onCommandStateChanged(CommandState? prev, CommandState next) {
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
      _autoHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _commandService?.dismiss();
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

  Future<void> _sendTextToAgent(String text) async {
    final current = ref.read(commandStateProvider).value?.current;
    if (current == null) return;

    final sourceLabel = '[from command: ${current.commandName}]';
    final message = await showSendToAgentComment(
      context: context,
      selectedText: text,
      sourceLabel: sourceLabel,
    );

    if (message == null || !mounted) return;
    // The comment dialog holds this open indefinitely, so `mounted` alone
    // doesn't mean the focused project still has a resolved session.
    final svc = focusedCheckoutServiceOrNull(ref.container, (s) => s.terminalService);
    if (svc == null) return;
    svc.sendToAgentTerminal(message);
    ref.read(switchToAgentProvider)?.call();
    showSentToAgentSnackBar(context);
  }

  void _sendFullOutputToAgent() {
    final current = ref.read(commandStateProvider).value?.current;
    if (current == null) return;
    final outputText = current.output.value;
    if (outputText.isEmpty) return;
    _sendTextToAgent(outputText);
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
    ref.listen(commandStateProvider, (prev, next) {
      _onCommandStateChanged(
        prev?.value,
        next.value ?? const CommandState(),
      );
    });

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
                  child: ValueListenableBuilder<String>(
                    valueListenable: current.output,
                    builder: (context, text, _) {
                      _scheduleScroll();
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
                              child: Text(
                                text.isEmpty ? ' ' : text,
                                style: AbTokens.monoStyle(
                                  fontSize: AbTokens.fontMd,
                                  height: 1.4,
                                  color: const Color(0xFFD4D4D4),
                                ),
                              ),
                            ),
                          ),
                          if (showSendButton)
                            SendToAgentButton(
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
