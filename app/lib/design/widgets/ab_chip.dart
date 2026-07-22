import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';

enum _AbChipVariant { system, label, toggle }

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
///
/// The two-axis split (font × chrome) is intentional: callers should not
/// have to mix-and-match independent flags. If you reach for a 4th
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
    };

    final interactive = widget.enabled && widget.onTap != null;
    if (!widget.enabled) return Opacity(opacity: 0.4, child: chip);
    if (!interactive) return chip;

    return Semantics(
      button: true,
      selected: widget._variant == _AbChipVariant.toggle
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
}
