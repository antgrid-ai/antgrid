import 'package:flutter/widgets.dart';

import '../../constants/breakpoints.dart';
import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';

/// Control sizing for phones: the extent every interactive control reserves
/// as its touch target, or 0 where precise pointers or desktop-density chrome
/// apply.
///
/// Phones only. A tablet is a mobile platform but renders the desktop layout,
/// whose dense toolbars a 48px floor would blow apart; the shortest side keeps
/// a landscape phone in and a portrait tablet out.
///
/// The widget itself is the opt-out: wrap fixed-height chrome (a toolbar whose
/// height is the design) in it and the controls inside size as on desktop.
/// It is deliberately not an [InheritedTheme], so a menu opened from that
/// chrome is touch-sized again.
class AbTouchSizing extends InheritedWidget {
  const AbTouchSizing.suppress({super.key, required super.child});

  static double extentOf(BuildContext context) {
    if (!isMobilePlatform) return 0;
    if (context.dependOnInheritedWidgetOfExactType<AbTouchSizing>() != null) {
      return 0;
    }
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null || size.shortestSide >= kCompactBreakpoint) return 0;
    return AbTokens.touchControlMin;
  }

  @override
  bool updateShouldNotify(AbTouchSizing oldWidget) => false;
}
