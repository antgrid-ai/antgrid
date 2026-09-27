import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';

enum _AbChipVariant { system, label, toggle, choice }

enum AbChipSize { sm, md }

/// Small categorical text affordance. Replaces the legacy `AbBadge`
/// (bordered pill) and `AbTag` (bare colored text) — those distinctions
/// are now expressed by constructor:
///
/// - [AbChip.system] — mono uppercase, bare colored text. For
///   system-assigned data (status, kind, tier). Read-only.
/// - [AbChip.label]  — sans, bare colored text. For human-language
///   labels (git status letters, free-form tags). Read-only.
/// - [AbChip.toggle] — mono uppercase inside a bordered pill, with
///   interactive selected/hover/focus states. For boolean toggles
///   (search options, filter chips).
/// - [AbChip.choice] — sans, as-written casing, inside a bordered pill.
///   For a one-of-N pick whose options are human-language phrases.
///
/// [toggle] and [choice] share the pill and differ only in how the label is
/// set, because they answer different questions. A toggle's label is a flag
/// name the user already knows (`CASE`, `REGEX`) and is legible as a shape at
/// 10px; uppercasing it costs nothing. A choice's label is a phrase the user
/// is reading to decide with, and uppercase plus letter-spacing flattens the
/// word shapes that make a phrase scannable — so it keeps its own casing, its
/// own size, and a text color that clears AA on the surfaces the pill sits on.
/// Picking [toggle] for a multi-word phrase is the mistake this exists to stop.
///
/// The two-axis split (font × chrome) is intentional: callers should not
/// have to mix-and-match independent flags. If you reach for a 5th
/// variant, that's the signal for a new named constructor.
///
/// Disabled-state contract:
///   - `enabled: true,  onTap: null` → informational, full opacity, no interaction.
///   - `enabled: true,  onTap: cb`   → interactive, full opacity, hover/focus/activation.
///   - `enabled: false`              → opacity 0.4, no interaction regardless of onTap.
class AbChip extends StatefulWidget {
  const AbChip.system({
    super.key,
    required this.label,
    this.color,
    this.size = AbChipSize.sm,
    this.onTap,
    this.enabled = true,
  }) : _variant = _AbChipVariant.system,
       selected = false;

  const AbChip.label({
    super.key,
    required this.label,
    this.color,
    this.size = AbChipSize.sm,
    this.onTap,
    this.enabled = true,
  }) : _variant = _AbChipVariant.label,
       selected = false;

  const AbChip.toggle({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.size = AbChipSize.sm,
    this.enabled = true,
  }) : _variant = _AbChipVariant.toggle;

  /// [color] accents the CHOSEN cell only. Left null, an unselected cell still
  /// paints at [AbColors.textSecondary] rather than dimming with it — every
  /// option in a one-of-N row has to stay readable, since the ones not taken
  /// are what the user is deciding between.
  const AbChip.choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.size = AbChipSize.md,
    this.enabled = true,
  }) : _variant = _AbChipVariant.choice;

  final String label;
  final Color? color;
  final AbChipSize size;
  final VoidCallback? onTap;
  final bool selected;
  final bool enabled;
  final _AbChipVariant _variant;

  @override
  State<AbChip> createState() => _AbChipState();
}

class _AbChipState extends State<AbChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? context.antgrid.textMuted;
    Widget chip = switch (widget._variant) {
      _AbChipVariant.system => _buildMonoText(c),
      _AbChipVariant.label => _buildSansText(c),
      _AbChipVariant.toggle => _buildPill(c, filled: widget.selected),
      _AbChipVariant.choice => _buildChoicePill(context),
    };

    final interactive = widget.enabled && widget.onTap != null;
    if (!widget.enabled) {
      return Opacity(opacity: AbTokens.opacityDisabled, child: chip);
    }
    if (!interactive) return chip;

    return Semantics(
      button: true,
      selected:
          widget._variant == _AbChipVariant.toggle ||
              widget._variant == _AbChipVariant.choice
          ? widget.selected
          : null,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: AbTokens.borderRadius3,
            child: chip,
          ),
        ),
      ),
    );
  }

  double get _monoFontSize => switch (widget.size) {
    AbChipSize.sm => 10,
    AbChipSize.md => 11,
  };

  double get _sansFontSize => switch (widget.size) {
    AbChipSize.sm => 11,
    AbChipSize.md => 12,
  };

  Widget _buildMonoText(Color c) => Text(
    widget.label.toUpperCase(),
    style: AbTokens.sansStyle(
      fontSize: _monoFontSize,
      fontWeight: FontWeight.w600,
      color: c,
    ).copyWith(letterSpacing: 1.0),
  );

  Widget _buildSansText(Color c) => Text(
    widget.label,
    style: AbTokens.sansStyle(
      fontSize: _sansFontSize,
      fontWeight: FontWeight.w600,
      color: c,
      height: 1.0,
    ),
  );

  Widget _buildPill(Color c, {required bool filled}) {
    final (hPad, vPad, fs) = switch (widget.size) {
      AbChipSize.sm => (AbTokens.space6, AbTokens.space2, 9.0),
      AbChipSize.md => (AbTokens.space8, AbTokens.space2, 10.0),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        color: filled ? c.withAlpha(40) : null,
        border: Border.all(color: c, width: 1),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        widget.label.toUpperCase(),
        style: AbTokens.sansStyle(
          fontSize: fs,
          fontWeight: FontWeight.w600,
          color: c,
        ).copyWith(letterSpacing: 0.8),
      ),
    );
  }

  Widget _buildChoicePill(BuildContext context) {
    final p = context.antgrid;
    // Unselected falls back to [AbColors.textSecondary], not [textMuted]:
    // muted measures 3.1-3.7:1 on the surfaces these rows sit on, under the
    // 4.5:1 AA floor for text this size, and an option nobody can read is not
    // an option. A caller passing [color] is naming the chosen cell's accent,
    // so the same fallback also carries the chosen-but-parked state, where the
    // fill says "picked" while the neutral tone withholds "in effect".
    final c = widget.color ?? p.textSecondary;
    final (hPad, vPad, fs) = switch (widget.size) {
      AbChipSize.sm => (AbTokens.space8, AbTokens.space4, AbTokens.fontXs),
      AbChipSize.md => (AbTokens.space10, AbTokens.space4, AbTokens.fontSm),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        color: widget.selected ? c.withAlpha(38) : null,
        // An unselected edge stays neutral whatever the accent is: five borders
        // in the accent would read as five chosen cells.
        border: Border.all(
          color: widget.selected ? c : p.borderStrong,
          width: 1,
        ),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        widget.label,
        style: AbTokens.sansStyle(
          fontSize: fs,
          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
          color: c,
          height: 1.2,
        ),
      ),
    );
  }
}
