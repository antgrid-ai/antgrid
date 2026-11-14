import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import 'carbon_empty_state.dart';

/// Shown when no preview tab is open. Opening one is done from the panel's
/// address bar above (type a port, press Enter). Mounts under the Preview
/// screen's Carbon scope.
class PreviewEmptyState extends StatelessWidget {
  const PreviewEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const CarbonEmptyState(
      icon: CarbonIcons.applicationWeb,
      heading: 'Open a Preview',
      body: 'Enter a dev server port above\nto preview it here',
    );
  }
}
