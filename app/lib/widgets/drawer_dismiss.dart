import 'package:flutter/material.dart' show Navigator, Scaffold;
import 'package:flutter/widgets.dart';

/// Mobile: the drawer is a slide-in overlay, so an action that navigates
/// elsewhere must dismiss it or the destination stays hidden behind it. No-op on
/// desktop, where the drawer is always-on chrome rather than a route.
///
/// Shared rather than duplicated: [projects_drawer.dart] and
/// [tasks_surface.dart] both call this from a widget nested under the same
/// mobile `Scaffold.drawer`, and a copy in either would drift from the other.
void closeDrawerIfOverlay(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold?.hasDrawer == true && scaffold!.isDrawerOpen) {
    Navigator.of(context).pop();
  }
}
