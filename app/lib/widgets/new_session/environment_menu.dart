import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../providers/new_session_picker.dart';
import 'picker_sources.dart';

/// Environment chip for the New Session composer: shows the picker's visible
/// source (Local or a machine) and opens a grouped source panel on tap.
/// Selection writes [selectedSourceIdProvider] — the same provider the old
/// rail tabs wrote, so control-plane keep-alive (controlPlaneAliveTargetsProvider)
/// and target validation keep working unchanged.
class EnvironmentChip extends ConsumerWidget {
  const EnvironmentChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(visiblePickerSourceProvider);
    final label = source?.label ?? 'Local';
    final icon = (source?.isLocal ?? true)
        ? AbIcons.deviceDesktop
        : AbIcons.server;
    return ComposerChip(
      icon: icon,
      label: label,
      onTap: (ctx) async {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        await showAbPanel<void>(
          context: ctx,
          anchorRect: anchor,
          // The composer sits at the bottom of the screen, so the panel
          // should open upward toward the visible content.
          preferred: AbMenuPlacement.above,
          builder: (_) => const EnvironmentPanel(),
        );
      },
    );
  }
}

/// Panel content: a LOCAL section (when a Local source exists) and a
/// MACHINES section with one row per remote machine. Live (ConsumerWidget) so
/// an inventory refresh updates rows while open.
class EnvironmentPanel extends ConsumerWidget {
  const EnvironmentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(pickerSourcesProvider);
    final visibleId = ref.watch(visiblePickerSourceProvider)?.id;
    final locals = sources.where((s) => s.isLocal).toList();
    final machines = sources
        .where((s) => !s.isLocal && s.machineUuid != null)
        .toList();

    void select(PickerSource s) {
      ref.read(selectedSourceIdProvider.notifier).set(s.id);
      Navigator.of(context).pop();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (locals.isNotEmpty) ...[
          const PanelSectionHeader('Local'),
          for (final s in locals)
            PanelRow(
              icon: AbIcons.deviceDesktop,
              label: s.label,
              selected: s.id == visibleId,
              onTap: () => select(s),
            ),
        ],
        const PanelSectionHeader('Machines'),
        if (machines.isEmpty)
          const PanelHint('No machines on this account')
        else
          for (final s in machines)
            PanelRow(
              icon: AbIcons.server,
              label: s.label,
              selected: s.id == visibleId,
              onTap: () => select(s),
            ),
      ],
    );
  }
}

/// Compact bordered chip for the composer's context row: `[icon] label
/// [chevron]`. Mono label — environment/project names are identifiers, not UI
/// chrome prose. Shared by Tasks 6-8 (environment/project/agent chips).
///
/// Builder-style [onTap] so the chip's own render box (not some ancestor's)
/// anchors the popup: the callback receives the [BuildContext] positioned
/// just above the chip's content, ready for [abMenuAnchorRect].
class ComposerChip extends StatelessWidget {
  const ComposerChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.attention = false,
  });

  final String icon;
  final String label;
  final void Function(BuildContext anchorContext) onTap;

  /// Accent styling for "needs a pick" states (e.g. "Select project…").
  final bool attention;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Builder(
        builder: (ctx) {
          final p = ctx.antgrid;
          final fg = attention ? p.accent : p.textPrimary;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(ctx),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space8,
                vertical: AbTokens.space4,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: attention ? p.accent : p.borderDefault,
                ),
                borderRadius: AbTokens.borderRadius3,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AbIcon(icon, size: 12, color: fg),
                  const SizedBox(width: AbTokens.space6),
                  Text(
                    label,
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontSm,
                      color: fg,
                    ),
                  ),
                  const SizedBox(width: AbTokens.space6),
                  AbIcon(AbIcons.chevronDown, size: 10, color: p.textMuted),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Uppercase mono section header, mirroring `AbMenu`'s header treatment
/// (`app/lib/design/widgets/ab_menu.dart`) so grouped panels read as one
/// popup system.
class PanelSectionHeader extends StatelessWidget {
  const PanelSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Text(
        label.toUpperCase(),
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          letterSpacing: 0.66,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Hover-highlighted row: `[icon] label ... [trailing] [check when
/// selected]`. Visually mirrors `_MenuItemTile` in `ab_menu.dart` — same
/// padding, radius, and hover background — so panel rows and menu items read
/// as the same control under different popup content. Like `_MenuItemTile` it
/// is keyboard-operable: it takes focus (highlighted the same as hover) and
/// Enter/Space/NumpadEnter activate it, so `showAbPanel` rows are reachable by
/// Tab traversal, not mouse-only.
class PanelRow extends StatefulWidget {
  const PanelRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<PanelRow> createState() => _PanelRowState();
}

class _PanelRowState extends State<PanelRow> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Treat keyboard focus the same as pointer hover for the highlight — one
    // "active row" state for either input mode, matching `_MenuItemTile`.
    final active = _hover || _focused;
    final fg = active ? p.textPrimary : p.textSecondary;
    final iconFg = active ? p.textPrimary : p.textMuted;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) {
        if (_hover != v) setState(() => _hover = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active ? p.bgHover : null,
            borderRadius: AbTokens.borderRadius3,
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 9),
                child: AbIcon(widget.icon, size: 13, color: iconFg),
              ),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    color: fg,
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
              if (widget.selected) ...[
                const SizedBox(width: AbTokens.space6),
                AbIcon(AbIcons.check, size: 12, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Muted single-line hint row (non-interactive) — e.g. "No machines on this
/// account".
class PanelHint extends StatelessWidget {
  const PanelHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}
