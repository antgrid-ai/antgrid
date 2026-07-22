import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../design/widgets/ab_icon.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../models/command_models.dart';
import '../models/ab_message.dart' show CommandInfo;
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../design/widgets/ab_loading.dart';

class CommandTray extends ConsumerWidget {
  const CommandTray({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = ref.watch(commandsProvider);
    if (commands.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    for (var i = 0; i < commands.length; i++) {
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
            child: Container(
              width: 1,
              height: 16,
              color: context.antgrid.borderSubtle,
            ),
          ),
        );
      }
      children.add(_CommandButton(command: commands[i]));
    }

    return Container(
      height: AbTokens.commandTrayHeight,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: Border(top: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
              child: Row(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandButton extends ConsumerStatefulWidget {
  final CommandInfo command;
  const _CommandButton({required this.command});

  @override
  ConsumerState<_CommandButton> createState() => _CommandButtonState();
}

class _CommandButtonState extends ConsumerState<_CommandButton> {
  bool _hovered = false;

  CommandStatus? _statusForCommand(CommandState? state) {
    final current = state?.current;
    if (current == null || current.commandName != widget.command.name) {
      return null;
    }
    return current.status;
  }

  @override
  Widget build(BuildContext context) {
    final cmdState = ref.watch(commandStateProvider).value;
    final status = _statusForCommand(cmdState);
    final isRunning = status == CommandStatus.running;

    // Status-aware colors
    final (Color bg, Color fg, Color border) = switch (status) {
      CommandStatus.running => (
        const Color(0xFF2A2518),
        Colors.amber,
        Colors.amber.withValues(alpha: 0.3),
      ),
      CommandStatus.success => (
        const Color(0xFF1A2A1A),
        context.antgrid.success,
        context.antgrid.success.withValues(alpha: 0.3),
      ),
      CommandStatus.failed => (
        const Color(0xFF2A1A1A),
        context.antgrid.error,
        context.antgrid.error.withValues(alpha: 0.3),
      ),
      _ => (
        _hovered
            ? context.antgrid.bgRaised.withValues(alpha: 0.5)
            : Colors.transparent,
        _hovered ? context.antgrid.textPrimary : context.antgrid.textSecondary,
        Colors.transparent,
      ),
    };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: isRunning ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: isRunning ? null : () => _runCommand(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space10,
            vertical: 5,
          ), // 5px non-ladder vertical for compact pill
          decoration: BoxDecoration(
            color: bg,
            borderRadius: AbTokens.borderRadius5,
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status/confirm indicator
              if (isRunning) ...[
                const AbLoadingDot(size: 12, color: Colors.amber),
                const SizedBox(width: AbTokens.space6),
              ] else if (widget.command.confirm) ...[
                AbIcon(
                  AbIcons.shield,
                  size: 12,
                  color: context.antgrid.error.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 5), // 5px non-ladder shield gap
              ],
              // Command name
              Text(
                widget.command.name,
                style: AbTokens.monoStyle(
                  fontWeight: FontWeight.w500,
                  color: fg,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _runCommand(BuildContext context) {
    final ref = this.ref;

    if (widget.command.confirm) {
      final colorScheme = Theme.of(context).colorScheme;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              AbIcon(AbIcons.shield, size: 18, color: colorScheme.error),
              const SizedBox(width: AbTokens.space8),
              Text(
                'Run "${widget.command.name}"?',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          content: const Text(
            'This command requires confirmation before executing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _sendCommandRun(ref, confirmed: true);
              },
              child: const Text('Run'),
            ),
          ],
        ),
      );
    } else {
      _sendCommandRun(ref);
    }
  }

  void _sendCommandRun(WidgetRef ref, {bool confirmed = false}) {
    // Presence guard only — CommandService derives the (bare) projectId from
    // its own session, so the compound registrationId must not be passed in.
    if (ref.read(selectedRegistrationIdProvider) == null) return;

    ref
        .read(commandServiceProvider)
        .runCommand(widget.command.name, confirmed: confirmed);
  }
}
