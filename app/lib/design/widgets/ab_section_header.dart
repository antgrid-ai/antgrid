import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_separator.dart';

/// The label over a run of list rows: an uppercase name, the size of the run,
/// and whatever that surface needs beside it.
///
/// Distinct from `AbToolbar.panel`, which titles a whole panel and owns a
/// fixed chrome band with its own bottom border. This lives *inside* a scroll
/// view and divides one list into groups.
class AbSectionHeader extends StatelessWidget {
  const AbSectionHeader({
    super.key,
    required this.label,
    this.count,
    this.color,
    this.trailing,
    this.rule = false,
    this.mono = false,
    this.padding = defaultPadding,
  });

  static const defaultPadding = EdgeInsets.symmetric(
    horizontal: AbTokens.space12,
  );

  /// Uppercased on render — pass whatever case reads best at the call site.
  final String label;

  /// Size of the run, appended as `· n`. Leave null where the group has no
  /// meaningful total (an unbounded feed).
  final int? count;

  /// Defaults to `textMuted`. Tint it only where the boundary itself carries
  /// urgency the rows beneath it cannot.
  final Color? color;

  final Widget? trailing;

  /// Draws a hairline from the label out to the trailing edge. Suits a header
  /// with width to spare; a narrow panel reads better without it.
  final bool rule;

  /// Mono where the label is a NAME the user could type — a machine, a
  /// project, a ref. Sans (the default) where it is a fixed category word,
  /// per the font rule in the design system.
  final bool mono;

  final EdgeInsetsGeometry padding;

  /// One value for both fonts. The label is a handful of uppercase glyphs at
  /// [AbTokens.fontXxs], where tracking is what keeps it from reading as a
  /// single blot.
  static const _letterSpacing = 0.8;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.antgrid.textMuted;
    final style = mono
        ? AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: color,
            letterSpacing: _letterSpacing,
          )
        : AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: _letterSpacing,
          );
    final count = this.count;
    final trailing = this.trailing;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          // Flexible, not bare Text: a project name lands here on the drawer's
          // grouped list and has no bound of its own.
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: AbTokens.space6),
            Text('· $count', style: style),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AbTokens.space8),
            trailing,
          ],
          if (rule) ...[
            const SizedBox(width: AbTokens.space10),
            const Expanded(child: AbSeparator.horizontal()),
          ],
        ],
      ),
    );
  }
}

/// [AbSectionHeader] pinned to the top of its scroll view.
///
/// A boundary that scrolls away takes with it the only thing saying which
/// group the row under the user's thumb belongs to — worth pinning wherever a
/// single group can run longer than a screen.
class AbSliverSectionHeader extends StatelessWidget {
  const AbSliverSectionHeader({
    super.key,
    required this.label,
    required this.background,
    this.count,
    this.color,
    this.mono = false,
    this.padding = AbSectionHeader.defaultPadding,
  });

  final String label;

  /// Required, unlike on the unpinned header: rows scroll UNDER a pinned one,
  /// and a transparent header shows them sliding through its own label.
  final Color background;

  final int? count;
  final Color? color;
  final bool mono;
  final EdgeInsetsGeometry padding;

  // No `trailing` here on purpose. A widget field would have to be compared by
  // identity in `shouldRebuild`, so anything but a `const` would rebuild the
  // header on every scroll frame.

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedSectionHeader(
        label: label,
        count: count,
        color: color,
        mono: mono,
        padding: padding,
        background: background,
      ),
    );
  }
}

class _PinnedSectionHeader extends SliverPersistentHeaderDelegate {
  const _PinnedSectionHeader({
    required this.label,
    required this.count,
    required this.color,
    required this.mono,
    required this.padding,
    required this.background,
  });

  final String label;
  final int? count;
  final Color? color;
  final bool mono;
  final EdgeInsetsGeometry padding;
  final Color background;

  static const _height = AbTokens.rowHeightSm;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: _height,
      color: background,
      alignment: Alignment.centerLeft,
      child: AbSectionHeader(
        label: label,
        count: count,
        color: color,
        mono: mono,
        padding: padding,
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedSectionHeader old) =>
      label != old.label ||
      count != old.count ||
      color != old.color ||
      mono != old.mono ||
      padding != old.padding ||
      background != old.background;
}
