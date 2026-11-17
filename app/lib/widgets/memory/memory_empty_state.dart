import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../carbon_empty_state.dart';

/// The Memory pane's name for [CarbonEmptyState], kept so its callers read in
/// their own vocabulary (`title`/`subtitle`).
class MemoryEmptyState extends StatelessWidget {
  const MemoryEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.error = false,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final bool error;
  final CarbonIcons? icon;

  @override
  Widget build(BuildContext context) => CarbonEmptyState(
    heading: title,
    body: subtitle,
    action: action,
    error: error,
    icon: icon,
  );
}
