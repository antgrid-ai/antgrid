import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';
import 'ab_separator.dart';

enum AbCmdState { idle, running, success, error }

class AbCmd {
  const AbCmd({
    required this.name,
    this.state = AbCmdState.idle,
    this.last,
    this.onTap,
  });
  final String name;
  final AbCmdState state;
  final String? last;
  final VoidCallback? onTap;
}

class AbCmdBar extends StatelessWidget {
  const AbCmdBar({
    super.key,
    required this.commands,
    required this.onRun,
    required this.onAdd,
    this.runShortcut = '⌘R',
  });

  final List<AbCmd> commands;
  final VoidCallback onRun;
  final VoidCallback onAdd;
  final String runShortcut;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final children = <Widget>[];
    for (var i = 0; i < commands.length; i++) {
      if (i > 0) {
        children.add(const AbSeparator.vertical());
      }
      children.add(_CmdButton(cmd: commands[i]));
    }

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(color: p.borderSubtle),
      ),
      child: Row(
        children: [
          ...children,
          const Spacer(),
          _RunChip(label: 'Run', shortcut: runShortcut, onTap: onRun),
          const SizedBox(width: 6),
          _IconAction(icon: AbIcons.add, onTap: onAdd),
        ],
      ),
    );
  }
}

class _CmdButton extends StatefulWidget {
  const _CmdButton({required this.cmd});
  final AbCmd cmd;

  @override
  State<_CmdButton> createState() => _CmdButtonState();
}

class _CmdButtonState extends State<_CmdButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final running = widget.cmd.state == AbCmdState.running;
    final mainColor = running
        ? p.statusRunning
        : (_hover ? p.textPrimary : p.textMuted);

    Widget? lastWidget;
    final last = widget.cmd.last;
    if (last != null) {
      Color lastColor = p.textDisabled;
      String prefix = '';
      switch (widget.cmd.state) {
        case AbCmdState.success:
          prefix = '✓ ';
          lastColor = p.statusRunning;
          break;
        case AbCmdState.error:
          prefix = '✗ ';
          lastColor = p.error;
          break;
        case AbCmdState.running:
          lastColor = p.statusRunning.withValues(alpha: 0.7);
          break;
        case AbCmdState.idle:
          lastColor = p.textDisabled;
          break;
      }
      lastWidget = Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(
          '$prefix$last',
          style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: lastColor),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.cmd.onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: _hover ? p.bgHover.withValues(alpha: 0.4) : Colors.transparent,
          child: Row(
            children: [
              Text(
                widget.cmd.name,
                style: TextStyle(
                  fontSize: AbTokens.fontMd,
                  fontWeight: FontWeight.w500,
                  color: mainColor,
                ),
              ),
              ...?lastWidget != null ? [lastWidget] : null,
            ],
          ),
        ),
      ),
    );
  }
}

class _RunChip extends StatelessWidget {
  const _RunChip({
    required this.label,
    required this.shortcut,
    required this.onTap,
  });
  final String label;
  final String shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: p.bgRaised,
          border: Border.all(color: p.borderSubtle),
          borderRadius: AbTokens.borderRadius5,
        ),
        child: Row(
          children: [
            Text(label, style: TextStyle(fontSize: AbTokens.fontXs, color: p.textMuted)),
            const SizedBox(width: 4),
            Text(
              shortcut,
              style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.onTap});
  final String icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: p.borderSubtle)),
        ),
        child: AbIcon(icon, size: 12, color: p.textMuted),
      ),
    );
  }
}
