import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_focus_ring.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_tooltip.dart';
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

/// Leading glyph size shared by [ComposerChip] and [ComposerToggleChip].
const double _chipGlyphSize = 12;

/// Trailing chevron size — smaller than the leading glyph: it is punctuation,
/// not identity.
const double _chipChevronSize = 10;

/// What a composer chip spends before its label: horizontal padding, the 1px
/// border on each side, and the leading glyph. Also the chip's floor — this
/// much is what a chip stripped down to its glyph still occupies, so a row
/// that reserves it can never squeeze a chip into an overflow.
const double kComposerChipGlyphWidth =
    AbTokens.space8 * 2 + 2 + _chipGlyphSize;

/// What the trailing chevron costs on top of [kComposerChipGlyphWidth]: the
/// gap that separates it from the label, plus its own glyph.
const double kComposerChipChevronWidth = AbTokens.space6 + _chipChevronSize;

/// Room a label needs before it is worth drawing at all — roughly four mono
/// characters, plus the gap after the leading glyph so this adds straight onto
/// a slot width. Anything less renders as a lone ellipsis, which says less
/// than the glyph it sits beside already does.
const double kComposerChipMinLabelWidth = AbTokens.space6 + 30;

/// Slot width at which a [ComposerChip] still renders `[glyph] label
/// [chevron]`. Narrower slots fall back to the glyph alone.
const double kComposerChipFullMinWidth =
    kComposerChipGlyphWidth +
    kComposerChipChevronWidth +
    kComposerChipMinLabelWidth;

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
          final labelStyle = AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            color: fg,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              // A chip is handed a slot, it doesn't ask for one: the context
              // row caps machine/project and gives the branch whatever is
              // left, so the slot can land below what the chip would rather
              // draw. Shed the label and the chevron together — a chevron
              // beside an ellipsis is chrome pointing at nothing — and let the
              // glyph stand in, rather than overflowing the row.
              final showLabel =
                  constraints.maxWidth >= kComposerChipFullMinWidth;
              // Genuinely no room: nothing can be tapped in zero pixels.
              if (constraints.maxWidth <= 0) {
                return const SizedBox.shrink();
              }
              final body = Container(
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
                child: SizedBox(
                  height: showLabel
                      ? null
                      : _measureLabel(context, label, labelStyle).height,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AbIcon(icon, size: _chipGlyphSize, color: fg),
                      if (showLabel) ...[
                        const SizedBox(width: AbTokens.space6),
                        // Ellipsize rather than overflow: labels are
                        // user/machine supplied (a machine name can carry
                        // a device-uuid suffix), so the chip must survive
                        // a narrow row. Requires callers to give the chip
                        // a bounded width — a flex slot, not a bare Row
                        // child.
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                        const SizedBox(width: AbTokens.space6),
                        AbIcon(
                          AbIcons.chevronDown,
                          size: _chipChevronSize,
                          color: p.textMuted,
                        ),
                      ],
                    ],
                  ),
                ),
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(ctx),
                child: _chipInSlot(constraints.maxWidth, body),
              );
            },
          );
        },
      ),
    );
  }
}

/// Boolean sibling of [ComposerChip]: identical metrics and typography, but a
/// leading state glyph replaces the trailing chevron — this chip commits a
/// value instead of opening a picker, and the row has to say which at a glance.
///
/// Deliberately not [AbChip.toggle]: that pill is a 9pt uppercase filter tag
/// and would read as a badge dropped among the pickers rather than as another
/// term in the context row's sentence.
class ComposerToggleChip extends StatefulWidget {
  const ComposerToggleChip({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
  });

  final String label;
  final bool value;

  /// Null disables the chip. Pair it with [tooltip] — a chip this size has no
  /// room to spell out why it is dead.
  final ValueChanged<bool>? onChanged;

  final String? tooltip;

  @override
  State<ComposerToggleChip> createState() => _ComposerToggleChipState();
}

class _ComposerToggleChipState extends State<ComposerToggleChip> {
  bool _focused = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final enabled = widget.onChanged != null;
    // Only the glyph carries the on/off state; the chip's frame and label stay
    // neutral so a toggled chip doesn't read as a pressed button.
    final fg = !enabled
        ? p.textDisabled
        : widget.value
        ? p.accent
        : p.textSecondary;

    final labelStyle = AbTokens.monoStyle(
      fontSize: AbTokens.fontSm,
      color: enabled ? p.textSecondary : p.textDisabled,
    );

    Widget chip = LayoutBuilder(
      builder: (context, constraints) {
        // All-or-nothing, unlike [ComposerChip]: this chip's label is a
        // constant and its only word, so an ellipsized stub of it carries
        // nothing the state glyph doesn't already carry. Measuring is what
        // makes that decision exact at any text scale.
        final labelSize = _measureLabel(context, widget.label, labelStyle);
        final showLabel =
            constraints.maxWidth >=
            kComposerChipGlyphWidth + AbTokens.space6 + labelSize.width;
        if (constraints.maxWidth <= 0) {
          return const SizedBox.shrink();
        }
        final body = AnimatedContainer(
          duration: AbTokens.motionDefault,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space8,
            vertical: AbTokens.space4,
          ),
          decoration: BoxDecoration(
            border: Border.all(
              color: enabled ? p.borderDefault : p.borderSubtle,
            ),
            borderRadius: AbTokens.borderRadius3,
          ),
          child: SizedBox(
            height: showLabel ? null : labelSize.height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AbIcon(
                  widget.value ? AbIcons.circleCheck : AbIcons.circle,
                  size: _chipGlyphSize,
                  color: fg,
                ),
                if (showLabel) ...[
                  const SizedBox(width: AbTokens.space6),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
        // Same slot contract as [ComposerChip]: new_session_composer's
        // isolationChipMax can hand this chip less than the icon-only
        // footprint.
        return _chipInSlot(constraints.maxWidth, body);
      },
    );

    final tooltip = widget.tooltip;
    if (tooltip != null) chip = AbTooltip(message: tooltip, child: chip);

    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.value,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
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
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Stays live while disabled so the chip keeps a hit area for the
          // tooltip that carries the reason; [_toggle] no-ops without a
          // callback.
          onTap: _toggle,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: AbTokens.borderRadius3,
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// Binds [body] to the [slotWidth] a chip was handed, scaling it only for a
/// slot narrower than [kComposerChipGlyphWidth].
///
/// Scaling is the last resort, for a slot below even the glyph-only footprint —
/// a bare `SizedBox.shrink` there silently dropped a chip whenever the composer
/// row's cap/floor math left one that narrow, and an unguarded chip sizes itself
/// off its Row's intrinsic content regardless, which is a render overflow rather
/// than a truncation. Above that width the chip has already shed its label to
/// fit, and a [FittedBox] is NOT the same fallback: it lays its child out
/// unbounded, so the label never reaches its ellipsis and the whole chip —
/// border, padding and text together — shrinks, leaving each chip on the row a
/// different height.
Widget _chipInSlot(double slotWidth, Widget body) => ConstrainedBox(
  constraints: BoxConstraints(maxWidth: slotWidth),
  child: slotWidth < kComposerChipGlyphWidth
      ? FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: body,
        )
      : body,
);

/// Size [label] would occupy unwrapped, at the ambient text scale. The width
/// decides whether a constant label is worth drawing; the height is what a
/// label-less chip pins itself to, so shedding the word doesn't also shrink the
/// chip out of line with its neighbours.
Size _measureLabel(BuildContext context, String label, TextStyle style) {
  // Merge the ambient default the way [Text] itself does — the chip's styles
  // leave `height` unset, so measuring the bare style would miss the theme's
  // line-height multiplier and under-report by a few pixels.
  final merged = DefaultTextStyle.of(context).style.merge(style);
  final painter = TextPainter(
    text: TextSpan(text: label, style: merged),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  return painter.size;
}

/// Uppercase mono section header, mirroring `AbMenu`'s header treatment
/// (`app/lib/design/widgets/ab_menu.dart`) so grouped panels read as one
/// popup system.
class PanelSectionHeader extends StatelessWidget {
  const PanelSectionHeader(this.label, {super.key, this.mono = true});

  final String label;

  /// False for a panel of navigational chrome (e.g. the workspace menu's
  /// "Workspace" header) rather than a picker over identifiers — sans is the
  /// font-token rule for chrome, mono for data (see app/CLAUDE.md's Design
  /// Rules). Defaults true: every existing caller here is an
  /// environment/branch/project picker, where the rows below ARE identifiers.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final style = mono ? AbTokens.monoStyle : AbTokens.sansStyle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Text(
        label.toUpperCase(),
        style: style(
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
    this.mono = true,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  /// False for a panel of navigational chrome rather than a picker over
  /// identifiers — see [PanelSectionHeader.mono], same rule and same default.
  final bool mono;

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
                  style: (widget.mono ? AbTokens.monoStyle : AbTokens.sansStyle)(
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
