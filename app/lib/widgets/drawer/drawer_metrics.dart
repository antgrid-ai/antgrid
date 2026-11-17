import 'package:carbon_flutter/carbon_flutter.dart';

/// Gap between the drawer's end border and the outermost trailing glyph's cell.
///
/// Every row's trailing glyph centres at
/// `panelRight - endBorder - kDrawerRailInset - drawerRailCell / 2`, which is
/// what keeps the status/action column on one vertical line across machine,
/// project and session rows.
const double kDrawerRailInset = CarbonSpacing.spacing04;

/// The square a trailing or leading glyph is centred in: a Carbon extra-small
/// control on a pointer, a full touch target on a phone or tablet.
double drawerRailCell(CarbonThemeData t) =>
    t.isTouch ? t.minTarget : CarbonSizes.xs;

/// How far a session row's leading slot sits right of its project's leading
/// slot: one glyph and the gap that follows it, so the name lines up under the
/// project title.
double drawerNestStep(CarbonThemeData t) => t.iconSize + CarbonSpacing.spacing03;

/// The docked drawer's width on desktop. The pane the shell hosts it in is
/// wider and owned there.
const double kDrawerPanelWidth = 288;
