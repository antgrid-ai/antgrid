import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';

/// Opt-in sizing for controls on touch surfaces, including popup routes.
class AbTouchSizing extends InheritedTheme {
  const AbTouchSizing({super.key, required super.child});

  static double extentOf(BuildContext context) =>
      isMobilePlatform &&
          context.dependOnInheritedWidgetOfExactType<AbTouchSizing>() != null
      ? AbTokens.touchControlMin
      : 0;

  @override
  bool updateShouldNotify(AbTouchSizing oldWidget) => false;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      AbTouchSizing(child: child);
}
