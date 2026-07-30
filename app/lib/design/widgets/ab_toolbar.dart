import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';

/// Canonical row primitive. Three named constructors enforce a consistent
/// height, padding, and baseline alignment for every toolbar/header/action
/// row in the app. Call sites pass content only — no height, no padding.
class AbToolbar extends StatelessWidget {
  /// Panel header: uppercase title left, optional [leading] icon, [actions]
  /// and optional [trailing] expand button on the right.
  /// Height: [AbTokens.rowHeightMd] (38px).
  const AbToolbar.panel({
    super.key,
    required String title,
    Widget? leading,
    List<Widget> actions = const [],
    Widget? trailing,
    bool border = true,
  }) : _variant = _ToolbarVariant.panel,
       _title = title,
       _leading = leading,
       _actions = actions,
       _trailing = trailing,
       _center = null,
       _tabs = null,
       _custom = null,
       _customHeight = null,
       _border = border;

  /// Action bar: dense row of [leading] icon buttons, optional [center]
  /// expanding content (e.g. URL bar), and [trailing] icon buttons.
  /// Height: [AbTokens.rowHeightSm] (32px).
  const AbToolbar.actions({
    super.key,
    List<Widget> leading = const [],
    Widget? center,
    List<Widget> trailing = const [],
    bool border = true,
  }) : _variant = _ToolbarVariant.actions,
       _title = null,
       _leading = null,
       _actions = leading,
       _trailing = null,
       _center = center,
       _tabs = trailing,
       _custom = null,
       _customHeight = null,
       _border = border;

  /// Tab strip: scrollable [tabs] + [trailing] action group.
  /// Height: [AbTokens.rowHeightSm] (32px).
  const AbToolbar.tabs({
    super.key,
    required List<Widget> tabs,
    List<Widget> trailing = const [],
    bool border = true,
  }) : _variant = _ToolbarVariant.tabs,
       _title = null,
       _leading = null,
       _actions = trailing,
       _trailing = null,
       _center = null,
       _tabs = tabs,
       _custom = null,
       _customHeight = null,
       _border = border;

  /// Escape hatch: arbitrary [children] inherit the canonical chrome
  /// (height, padding, background, optional border) without being forced
  /// into a title/icon-row template. Use for primary headers whose content
  /// doesn't fit [AbToolbar.panel] (e.g. mono-styled agent name).
  /// Height: [height] or [AbTokens.rowHeightMd] (38px) by default.
  const AbToolbar.custom({
    super.key,
    required List<Widget> children,
    double? height,
    bool border = true,
  }) : _variant = _ToolbarVariant.custom,
       _title = null,
       _leading = null,
       _actions = null,
       _trailing = null,
       _center = null,
       _tabs = null,
       _custom = children,
       _customHeight = height,
       _border = border;

  final _ToolbarVariant _variant;
  final String? _title;
  final Widget? _leading;
  final List<Widget>? _actions;
  final Widget? _trailing;
  final Widget? _center;
  final List<Widget>? _tabs;
  final List<Widget>? _custom;
  final double? _customHeight;
  final bool _border;

  double get _height => switch (_variant) {
    _ToolbarVariant.panel => AbTokens.rowHeightMd,
    _ToolbarVariant.actions => AbTokens.rowHeightSm,
    _ToolbarVariant.tabs => AbTokens.rowHeightSm,
    _ToolbarVariant.custom => _customHeight ?? AbTokens.rowHeightMd,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _height,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space4),
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: _border
            ? Border(bottom: BorderSide(color: context.antgrid.borderSubtle))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: switch (_variant) {
          _ToolbarVariant.panel => _panelChildren(context),
          _ToolbarVariant.actions => _actionsChildren(),
          _ToolbarVariant.tabs => _tabsChildren(),
          _ToolbarVariant.custom => _customChildren(),
        },
      ),
    );
  }

  List<Widget> _panelChildren(BuildContext context) {
    final title = _title;
    final leading = _leading;
    final trailing = _trailing;
    final actions = _actions ?? const [];

    return [
      if (leading != null) ...[leading, const SizedBox(width: AbTokens.space8)],
      // Expanded, not Text + Spacer: a bare Text cannot shrink, so a long
      // title or a large text scale overflowed the row instead of ellipsizing.
      // Expanded eats the same slack the Spacer did, so short titles are
      // laid out identically.
      Expanded(
        child: Text(
          title!.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AbTokens.fontSans,
            fontFamilyFallback: AbTokens.fontSansFallbacks,
            fontSize: AbTokens.fontXxs,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.5,
            color: context.antgrid.textSecondary,
            height: 1.0, // line-metric centers caps inside the row
          ),
        ),
      ),
      ..._withSeparators(actions, separator: AbTokens.space4),
      if (trailing != null) ...[
        const SizedBox(width: AbTokens.space8),
        trailing,
      ],
    ];
  }

  List<Widget> _actionsChildren() {
    final leading = _actions ?? const [];
    final center = _center;
    final trailing = _tabs ?? const [];

    return [
      ..._withSeparators(leading, separator: AbTokens.space4),
      if (center != null) ...[
        const SizedBox(width: AbTokens.space8),
        Expanded(child: center),
        const SizedBox(width: AbTokens.space8),
      ] else
        const Spacer(),
      ..._withSeparators(trailing, separator: AbTokens.space4),
    ];
  }

  List<Widget> _tabsChildren() {
    final actions = _actions ?? const <Widget>[];
    return [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: _withSeparators(
              _tabs ?? const [],
              separator: AbTokens.space2,
            ),
          ),
        ),
      ),
      if (actions.isNotEmpty) ...[
        const SizedBox(width: AbTokens.space8),
        ..._withSeparators(actions, separator: AbTokens.space4),
      ],
    ];
  }

  List<Widget> _customChildren() => _custom!;

  static List<Widget> _withSeparators(
    List<Widget> children, {
    required double separator,
  }) {
    if (children.isEmpty) return const [];
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) result.add(SizedBox(width: separator));
      result.add(children[i]);
    }
    return result;
  }
}

enum _ToolbarVariant { panel, actions, tabs, custom }
