import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';

/// Carbon's data table row heights.
enum CarbonDataTableSize {
  /// 24.
  extraSmall,

  /// 32.
  small,

  /// 40.
  medium,

  /// 48.
  large,

  /// 64.
  extraLarge,
}

/// Which edge of its column a column's label and cells sit against.
enum CarbonDataTableAlign {
  /// The leading edge (left in LTR).
  start,

  /// The trailing edge, for numbers.
  end,
}

/// One column of a [CarbonDataTable].
class CarbonDataTableColumn {
  const CarbonDataTableColumn({
    required this.label,
    this.flex = 1,
    this.width,
    this.align = CarbonDataTableAlign.start,
  });

  /// The header text. May be empty for a status or actions column; an empty
  /// header is not announced.
  final String label;

  /// Share of the width left after fixed columns.
  final double flex;

  /// A fixed width including the cell padding; wins over [flex].
  final double? width;

  final CarbonDataTableAlign align;
}

/// One row of a [CarbonDataTable]: one cell widget per column.
class CarbonDataTableRow {
  const CarbonDataTableRow({
    this.key,
    required this.cells,
    this.selected = false,
    this.expansion,
  });

  final Key? key;
  final List<Widget> cells;

  /// Fills the row with `layer-selected` (`layer-selected-hover` while
  /// hovered) and marks it selected for assistive technology. The table has no
  /// selection column; the host decides what selects a row.
  final bool selected;

  /// Content shown below the cells at the table's full width, inside the
  /// row's own fill and above its bottom rule. The host owns whether it is
  /// open: pass null to collapse. The table draws no toggle.
  final Widget? expansion;
}

double _rowHeight(CarbonDataTableSize size) => switch (size) {
  CarbonDataTableSize.extraSmall => CarbonSizes.xs,
  CarbonDataTableSize.small => CarbonSizes.sm,
  CarbonDataTableSize.medium => CarbonSizes.md,
  CarbonDataTableSize.large => CarbonSizes.lg,
  CarbonDataTableSize.extraLarge => CarbonSizes.xl,
};

// Carbon fixes each row's block size and pads cells by hand per size. Padding
// that scales with the row keeps a single line inside its minimum height and
// still keeps wrapped text off the rules.
double _blockPadding(CarbonDataTableSize size) => switch (size) {
  CarbonDataTableSize.extraSmall => CarbonSpacing.spacing01,
  CarbonDataTableSize.small => CarbonSpacing.spacing02,
  CarbonDataTableSize.medium => CarbonSpacing.spacing03,
  CarbonDataTableSize.large => CarbonSpacing.spacing04,
  CarbonDataTableSize.extraLarge => CarbonSpacing.spacing05,
};

/// Carbon's data table for static rows: an optional title block, a column
/// header row, then body rows.
///
/// * The header row is filled with `layer-accent`, in `heading-compact-01`
///   `text-primary`. Body rows are filled with the current layer, in
///   `body-compact-01` `text-secondary`, separated by 1px `border-subtle`
///   rules. A hovered row fills with `layer-hover`, its rules follow and its
///   text turns `text-primary`; rows are not interactive, so hover is the only
///   state. A [CarbonDataTableRow.selected] row fills with `layer-selected`
///   and `layer-selected-hover` instead.
/// * [size] sets each row's minimum height; touch density floors every row at
///   [CarbonThemeData.touchTarget]. Rows grow with wrapped text and cells are
///   centred vertically.
/// * Header and body share one column layout, so edges line up. A column with
///   a [CarbonDataTableColumn.width] is fixed; the rest split what remains by
///   [CarbonDataTableColumn.flex].
/// * [title] uses `heading-03` and [description] `body-compact-01`
///   `text-secondary`. `heading-03` is the title role in compact density and
///   the large heading role in touch density, where both are 20/28.
/// * With no [rows], [emptyState] shows in a row-height region below the
///   header.
class CarbonDataTable extends StatelessWidget {
  const CarbonDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.size = CarbonDataTableSize.large,
    this.title,
    this.description,
    this.emptyState,
  });

  final List<CarbonDataTableColumn> columns;
  final List<CarbonDataTableRow> rows;
  final CarbonDataTableSize size;
  final String? title;
  final String? description;
  final Widget? emptyState;

  @override
  Widget build(BuildContext context) {
    assert(
      rows.every((row) => row.cells.length == columns.length),
      'Every CarbonDataTableRow needs exactly one cell per column.',
    );
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final minHeight = theme.isTouch
        ? _rowHeight(size).clamp(theme.touchTarget, double.infinity)
        : _rowHeight(size);
    final title = this.title;
    final description = this.description;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null)
          DecoratedBox(
            decoration: BoxDecoration(color: theme.layer(level)),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                top: CarbonSpacing.spacing05,
                bottom: CarbonSpacing.spacing06,
                start: CarbonSpacing.spacing05,
                end: CarbonSpacing.spacing05,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style:
                          (theme.isTouch
                                  ? theme.typography.headingLarge
                                  : theme.typography.title)
                              .copyWith(color: theme.colors.textPrimary),
                    ),
                  ),
                  if (description != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: CarbonSpacing.spacing03,
                      ),
                      child: Text(
                        description,
                        style: theme.typography.control.copyWith(
                          color: theme.colors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Semantics(
          role: SemanticsRole.table,
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _HeaderRow(
                columns: columns,
                minHeight: minHeight,
                blockPadding: _blockPadding(size),
              ),
              for (final row in rows)
                _BodyRow(
                  key: row.key,
                  columns: columns,
                  cells: row.cells,
                  selected: row.selected,
                  expansion: row.expansion,
                  minHeight: minHeight,
                  blockPadding: _blockPadding(size),
                ),
            ],
          ),
        ),
        if (rows.isEmpty && emptyState != null)
          DecoratedBox(
            decoration: BoxDecoration(color: theme.layer(level)),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CarbonSpacing.spacing05,
                    vertical: CarbonSpacing.spacing03,
                  ),
                  child: emptyState,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lays out one row of cells with the column widths every row shares.
Widget _cells({
  required List<CarbonDataTableColumn> columns,
  required Widget Function(int index) cell,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      for (var i = 0; i < columns.length; i++)
        if (columns[i].width != null)
          SizedBox(width: columns[i].width, child: cell(i))
        else
          // Expanded wants an int; the scale keeps fractional flex ratios.
          Expanded(flex: (columns[i].flex * 1000).round(), child: cell(i)),
    ],
  );
}

Widget _cellFrame(CarbonDataTableColumn column, TextStyle style, Widget child) {
  final end = column.align == CarbonDataTableAlign.end;
  return Padding(
    padding: const EdgeInsetsDirectional.symmetric(
      horizontal: CarbonSpacing.spacing05,
    ),
    child: Align(
      alignment: end
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: DefaultTextStyle(
        style: style,
        textAlign: end ? TextAlign.end : TextAlign.start,
        child: child,
      ),
    ),
  );
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.columns,
    required this.minHeight,
    required this.blockPadding,
  });

  final List<CarbonDataTableColumn> columns;
  final double minHeight;
  final double blockPadding;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final style = theme.typography.heading.copyWith(
      color: theme.colors.textPrimary,
    );
    return Semantics(
      role: SemanticsRole.row,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.layerAccent(level)),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: blockPadding + CarbonBorders.hairline,
            ),
            child: _cells(
              columns: columns,
              cell: (i) {
                final column = columns[i];
                final frame = _cellFrame(
                  column,
                  style,
                  Text(column.label, softWrap: true),
                );
                if (column.label.isEmpty) return ExcludeSemantics(child: frame);
                return Semantics(
                  role: SemanticsRole.columnHeader,
                  container: true,
                  child: frame,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _BodyRow extends StatefulWidget {
  const _BodyRow({
    super.key,
    required this.columns,
    required this.cells,
    required this.selected,
    required this.expansion,
    required this.minHeight,
    required this.blockPadding,
  });

  final List<CarbonDataTableColumn> columns;
  final List<Widget> cells;
  final bool selected;
  final Widget? expansion;
  final double minHeight;
  final double blockPadding;

  @override
  State<_BodyRow> createState() => _BodyRowState();
}

class _BodyRowState extends State<_BodyRow> {
  bool _hovered = false;

  void _setHover(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final colors = theme.colors;
    final restFill = widget.selected
        ? theme.layerSelected(level)
        : theme.layer(level);
    final fill = _hovered
        ? (widget.selected
              ? theme.layerSelectedHover(level)
              : theme.layerHover(level))
        : restFill;
    final style = theme.typography.control.copyWith(
      color: _hovered ? colors.textPrimary : colors.textSecondary,
    );
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Semantics(
        role: SemanticsRole.row,
        container: true,
        selected: widget.selected ? true : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            border: Border(
              // Hover recolours both rules to the fill so the row reads as one
              // block; at rest the top rule is the layer and the bottom the
              // subtle divider.
              top: BorderSide(
                color: _hovered ? fill : restFill,
                width: CarbonBorders.hairline,
              ),
              bottom: BorderSide(
                color: _hovered ? fill : theme.borderSubtle(level),
                width: CarbonBorders.hairline,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: widget.minHeight),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: widget.blockPadding + CarbonBorders.hairline,
                  ),
                  child: _cells(
                    columns: widget.columns,
                    cell: (i) => Semantics(
                      role: SemanticsRole.cell,
                      container: true,
                      child: _cellFrame(
                        widget.columns[i],
                        style,
                        widget.cells[i],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.expansion != null)
                // Not under the hover recolour: the content is free-form and
                // keeps whatever text colour it brings.
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: CarbonSpacing.spacing05,
                    end: CarbonSpacing.spacing05,
                    bottom: CarbonSpacing.spacing05,
                  ),
                  child: DefaultTextStyle(
                    style: theme.typography.control.copyWith(
                      color: colors.textSecondary,
                    ),
                    child: widget.expansion!,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
